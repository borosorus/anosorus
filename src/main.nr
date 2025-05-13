/*
    Could add a smart wallet try to repay function, to avoid liquidations, with incentive for liquidators

    Liquidation:
        Auction system, with high long term rewards for low collateral bonus

    Should use block number for acounting ?

    VIEWS
    SMART ACCOUNTS
    FEE_FOR_OWNER
    rEENtRANCY !
*/

mod loan;
mod balance;
mod asset;

use dep::aztec::macros::aztec;
//TODO ASSUMING 8 decimals

#[aztec]
pub contract Lending {
    use dep::aztec::prelude::{AztecAddress, Map, PublicMutable, PublicImmutable};

    use crate::loan::Loan;
    use crate::balance::Balance;
    use crate::asset::Asset;
    use dep::price_feed::PriceFeed;
    use dep::token::Token;

    use dep::aztec::macros::{
        functions::{initializer, internal, private, public},
        storage::storage,
    };

    use dep::aztec::protocol_types::traits::{FromField, ToField};
    use dep::aztec::hash::compute_secret_hash;

    #[contract_library_method]
    fn UNIT() -> u128 { 1000000000000000000 } // 1e18
    #[contract_library_method]
    fn MIN_DEBT() -> u128 { 200 * UNIT() } // 200 USD
    #[contract_library_method]
    fn LIQUIDATION_BONUS() -> u128 { (UNIT() * 110) / 100 } // 110 %
    #[contract_library_method]
    fn CLOSE_FACTOR() -> u128 { (UNIT() * 50) / 100 } // 50 %
    #[contract_library_method]
    fn LIQ_RESERVE_SHARE() -> u128 { (UNIT() * 5) / 100 } // 5%

    // Storage structure, containing all storage, and specifying what slots they use.
    #[storage]
    struct Storage<Context> {
        // Public Immutables
        base_token: PublicImmutable<AztecAddress, Context>,

        // Public Mutables
        reserve_fee: PublicMutable<u128, Context>,
        admin: PublicMutable<AztecAddress, Context>,

        collaterals: Map<AztecAddress, PublicMutable<Asset, Context>, Context>,
        collateral_reserve: Map<AztecAddress, PublicMutable<u128, Context>, Context>,

        loans: Map<Field, PublicMutable<Loan, Context>, Context>, // secret based loan

        total_debt: PublicMutable<u128, Context>,
        current_debt_index: PublicMutable<u128, Context>,
        current_supply_index: PublicMutable<u128, Context>,
        last_update_ts: PublicMutable<u64, Context>,
        available_base: PublicMutable<u128, Context>,
        reserve: PublicMutable<u128, Context>,
        balances: Map<Field, PublicMutable<Balance, Context>, Context>, // secret based balance, only public
    }

    //TODO public stters, reserve_fee, kink ? ts multip ? 

    #[public]
    #[initializer]
    fn constructor(base_token: AztecAddress) {
        assert(!base_token.is_zero(), "invalid base");

        storage.base_token.initialize(base_token);

        storage.admin.write(context.msg_sender());

        storage.reserve_fee.write((UNIT() * 15) / 100); // 15% on interests
        storage.current_debt_index.write(UNIT()); // Initialize debt index at 1
        storage.current_supply_index.write(UNIT()); // Initialize supply index at 1
        storage.last_update_ts.write(context.timestamp()); // Initialize ts now
    }

    /*
        ADMIN
    */

    #[public]
    fn add_collateral(address: AztecAddress, oracle: AztecAddress, ltv: u128) {
        assert(context.msg_sender() == storage.admin.read());
        assert(ltv < UNIT());

        let collateral = Asset { oracle: oracle, ltv: ltv, active: true };
        storage.collaterals.at(address).write(collateral);
    }

    #[public]
    fn set_collateral_state(address: AztecAddress) {
        assert(context.msg_sender() == storage.admin.read());
        let collat_slot = storage.collaterals.at(address);
        let mut collateral = collat_slot.read();
        collateral.active = !collateral.active;
        collat_slot.write(collateral);
    }

    #[public]
    fn withdraw_collateral_reserve(address: AztecAddress, to: AztecAddress) {
        assert(context.msg_sender() == storage.admin.read());
        let reserve_slot = storage.collateral_reserve.at(address);

        let _ = Token::at(address).transfer_in_public(context.this_address(), to, reserve_slot.read(), 0).call(&mut context);

        reserve_slot.write(0);
    }

    #[public]
    fn withdraw_base_reserve(to: AztecAddress) {
        assert(context.msg_sender() == storage.admin.read());
        let base_token = storage.base_token.read();
        let available_base = storage.available_base.read();

        let bal = Token::at(base_token).balance_of_public(context.this_address()).view(&mut context);

        let _ = Token::at(base_token).transfer_in_public(context.this_address(), to, bal - available_base, 0).call(&mut context);
    }

    /* 
        PUBLIC
    */

    #[public]
    fn accrue_interest() -> [u128; 2] {
        let current_ts = context.timestamp();
        let delta = current_ts - storage.last_update_ts.read();
        let mut current_debt_index = storage.current_debt_index.read();
        let mut current_supply_index = storage.current_supply_index.read();

        if delta > 0 {
            let total_debt = storage.total_debt.read();

            let BASE_RATE: u128 = 100000000;

            // TODO COMPUTE A BORROW RATE
            let utilization_rate = (total_debt * UNIT()) / (total_debt + storage.available_base.read());
            let borrow_rate_per_second = BASE_RATE * utilization_rate;
            //TODO 

            let interest_factor = borrow_rate_per_second * delta as u128;

            storage.total_debt.write(total_debt + (interest_factor * total_debt) / UNIT());

            current_debt_index = current_debt_index + (current_debt_index * interest_factor) / UNIT();
            current_supply_index = current_supply_index + ( current_supply_index * (interest_factor * utilization_rate) / UNIT() ) / UNIT();

            storage.current_debt_index.write(current_debt_index);
            storage.current_supply_index.write(current_supply_index);
            storage.last_update_ts.write(current_ts);
        }

        [current_debt_index, current_supply_index]
    }
    /*
        PRIVATE
    */
    
    #[private]
    fn deposit(
        base_token: AztecAddress,
        amount: u128,
        from: AztecAddress,
        on_behalf_of: Field,
        secret: Field,
        nonce: Field
    ) {
        let _ = Token::at(base_token)
            .transfer_to_public(from, context.this_address(), amount, nonce)
            .call(&mut context);
        
        let user_id = if on_behalf_of == 0 {compute_secret_hash(secret)} else {on_behalf_of};

        Lending::at(context.this_address())
            ._deposit(base_token, amount, user_id)
            .enqueue(&mut context);
    }

    #[private]
    fn withdraw(
        base_token: AztecAddress,
        amount: u128,
        to: AztecAddress,
        secret: Field,
    ) {
        let _ = Token::at(base_token)
            .transfer_to_private(to, amount)
            .call(&mut context);
        
        let user_id = compute_secret_hash(secret);

        Lending::at(context.this_address())
            ._withdraw(base_token, amount, user_id)
            .enqueue(&mut context);
    }

    #[private]
    fn borrow(
        collateral: AztecAddress,
        collateral_amount: u128,
        base_token: AztecAddress,
        debt_amount: u128,
        from: AztecAddress,
        to: AztecAddress,
        secret: Field,
        nonce: Field,
    ) {
        let _ = Token::at(collateral)
            .transfer_to_public(from, context.this_address(), collateral_amount, nonce)
            .call(&mut context);
        
        let _ = Token::at(base_token)
            .transfer_to_private(to, debt_amount)
            .call(&mut context);
        
        let loan_id = compute_secret_hash(secret);

        Lending::at(context.this_address())
            ._borrow(collateral, collateral_amount, base_token, debt_amount, loan_id)
            .enqueue(&mut context);
    }

    #[private]
    fn repay(
        collateral: AztecAddress,
        collateral_out_amount: u128,
        base_token: AztecAddress,
        debt: u128,
        from: AztecAddress,
        to: AztecAddress,
        secret: Field,
        nonce: Field,
    ) {
        assert(collateral.to_field() != 0);

        let _ = Token::at(collateral)
            .transfer_to_private(to, collateral_out_amount)
            .call(&mut context);
        let _ = Token::at(base_token)
            .transfer_to_public(from, context.this_address(), debt, nonce)
            .call(&mut context);

        let loan_id = compute_secret_hash(secret);

        Lending::at(context.this_address())
            ._repay(collateral, collateral_out_amount, base_token, debt, loan_id)
            .enqueue(&mut context);
    }

    #[private]
    fn repay_for(
        base_token: AztecAddress,
        debt: u128,
        from: AztecAddress,
        on_behalf_of: Field,
        nonce: Field,
    ) {
        let _ = Token::at(base_token)
            .transfer_to_public(from, context.this_address(), debt, nonce)
            .call(&mut context);
        
        Lending::at(context.this_address())
            ._repay(AztecAddress::from_field(0), 0 as u128, base_token, debt, on_behalf_of)
            .enqueue(&mut context);
    }

    #[private]
    fn liquidate(
        collateral: AztecAddress,
        collateral_amount: u128,
        base_token: AztecAddress,
        debt: u128, 
        from: AztecAddress,
        to: AztecAddress,
        nonce: Field,
        loan_id: Field,
    ) {
        let _ = Token::at(collateral)
            .transfer_to_private(to, collateral_amount)
            .call(&mut context);

        let _ = Token::at(base_token)
            .transfer_to_public(from, context.this_address(), debt, nonce)
            .call(&mut context);

        Lending::at(context.this_address())
            ._liquidate(collateral, collateral_amount, base_token, debt, loan_id)
            .enqueue(&mut context);
    }

    /*
        INTERNAL
    */
//todo total debt with accrued, hard to predict
    #[public]
    #[internal]
    fn _liquidate(
        collateral: AztecAddress,
        collateral_amount: u128,
        base_token: AztecAddress,
        debt: u128,
        loan_id: Field,
    ) {
        assert(base_token == storage.base_token.read());
        let current_indexes = Lending::at(context.this_address()).accrue_interest().call(&mut context);

        let loan_slot = storage.loans.at(loan_id);
        let mut loan = loan_slot.read();

        assert(loan.collateral == collateral);

        loan.debt = (loan.debt * current_indexes[0]) / loan.last_index - debt;
        loan.last_index = current_indexes[0];

        let collateral_asset = storage.collaterals.at(collateral).read();
        let collateral_price = PriceFeed::at(collateral_asset.oracle).get_price(loan.collateral.to_field()).view(&mut context).price;

        assert(!((loan.debt * UNIT()) / (loan.collateral_amount * collateral_price) < collateral_asset.ltv));

        let collateral_eq = (debt * LIQUIDATION_BONUS()) / collateral_price;
        loan.collateral_amount -= collateral_eq;

        let max_debt_to_repay = (loan.debt * CLOSE_FACTOR()) / UNIT();

        if((loan.debt - max_debt_to_repay) < MIN_DEBT()) {
            assert(debt >= loan.debt);
            loan.debt = 0;
        } else {
            assert(debt <= max_debt_to_repay);
            loan.debt -= debt;
            assert((loan.debt * UNIT()) / (loan.collateral_amount * collateral_price) < collateral_asset.ltv);
        }

        let reserve_share = (debt * LIQ_RESERVE_SHARE()) / collateral_price;
        let actual_share = collateral_amount - collateral_eq;
        assert(actual_share >= reserve_share);

        let coll_res_slot = storage.collateral_reserve.at(collateral);
        coll_res_slot.write(coll_res_slot.read() + actual_share);

        loan_slot.write(loan);
    }

    #[public]
    #[internal]
    fn _repay(
        collateral: AztecAddress,
        collateral_out_amount: u128,
        base_token: AztecAddress,
        debt: u128,
        loan_id: Field,
    ) {
        assert(storage.base_token.read() == base_token);
        let current_indexes = Lending::at(context.this_address()).accrue_interest().call(&mut context);

        let loan_slot = storage.loans.at(loan_id);
        let mut loan = loan_slot.read();

        loan.debt = (loan.debt * current_indexes[0]) / loan.last_index - debt;
        loan.last_index = current_indexes[0];

        assert( (loan.debt >= MIN_DEBT()) | (loan.debt == 0) );

        if(collateral.to_field() != 0) {
            assert(loan.collateral == collateral);

            loan.collateral_amount -= collateral_out_amount;
            if(loan.debt > 0) {
                let collateral_asset = storage.collaterals.at(collateral).read();
                let collateral_price = PriceFeed::at(collateral_asset.oracle).get_price(loan.collateral.to_field()).view(&mut context).price;
                assert((loan.debt * UNIT()) / (loan.collateral_amount * collateral_price) < collateral_asset.ltv);
            }
        }

        loan_slot.write(loan);
        storage.total_debt.write(storage.total_debt.read() - debt);
    }

    #[public]
    #[internal]
    fn _borrow(
        collateral: AztecAddress,
        collateral_amount: u128,
        base_token: AztecAddress,
        debt_amount: u128,
        loan_id: Field,
    ) {
        let collateral_asset = storage.collaterals.at(collateral).read();

        assert(collateral_asset.active);
        assert(base_token == storage.base_token.read());

        let current_indexes = Lending::at(context.this_address()).accrue_interest().call(&mut context);

        let loan_slot = storage.loans.at(loan_id);
        let mut loan = loan_slot.read();

        if( (loan.debt > 0) | (loan.collateral_amount > 0) ) {
            assert(loan.collateral == collateral);

            loan.debt = ((loan.debt * current_indexes[0]) / loan.last_index) + debt_amount;
            loan.last_index = current_indexes[0];

            loan.collateral_amount += collateral_amount;

            let collateral_price = PriceFeed::at(collateral_asset.oracle).get_price(loan.collateral.to_field()).view(&mut context).price;
            assert((loan.debt * UNIT()) / (loan.collateral_amount * collateral_price) < collateral_asset.ltv);

            loan_slot.write(loan);

        } else {
            assert(debt_amount >= MIN_DEBT());

            loan = Loan {collateral: collateral, collateral_amount: collateral_amount, debt: debt_amount, last_index: current_indexes[0]};

            let collateral_price = PriceFeed::at(collateral_asset.oracle).get_price(loan.collateral.to_field()).view(&mut context).price;
            assert((loan.debt * UNIT()) / (loan.collateral_amount * collateral_price) < collateral_asset.ltv);

            storage.loans.at(loan_id).write(loan);
        }

        storage.available_base.write(storage.available_base.read() - debt_amount);
        storage.total_debt.write(storage.total_debt.read() + debt_amount);
    }

    #[public]
    #[internal]
    fn _deposit(
        base_token: AztecAddress,
        amount: u128,
        user_id: Field,
    ) {
        assert(base_token == storage.base_token.read());

        let current_indexes = Lending::at(context.this_address()).accrue_interest().call(&mut context);
        Lending::at(context.this_address())._update_balance(user_id, current_indexes[1], amount, 0).call(&mut context);
    }

    #[public]
    #[internal]
    fn _withdraw(
        base_token: AztecAddress,
        amount: u128,
        user_id: Field, 
    ) {
        assert(base_token == storage.base_token.read());

        let current_indexes = Lending::at(context.this_address()).accrue_interest().call(&mut context);
        Lending::at(context.this_address())._update_balance(user_id, current_indexes[1], 0, amount).call(&mut context);
    }

    #[public]
    #[internal]
    fn _update_balance(
        user_id: Field,
        current_supply_index: u128,
        to_add: u128,
        to_sub: u128,
    ) {
        let balance_slot = storage.balances.at(user_id);
        let mut balance = balance_slot.read();
        let mut current_balance = if balance.amount > 0 {(balance.amount * current_supply_index) / balance.last_index } else {0};

        let reserve_fee = (storage.reserve_fee.read() * (current_balance - balance.amount)) / UNIT();

        current_balance = current_balance + to_add - reserve_fee;

        assert(current_balance >= to_sub);
        current_balance -= to_sub;

        balance.amount = current_balance;
        balance.last_index = current_supply_index;

        storage.available_base.write(storage.available_base.read() + to_add - to_sub);
    }
}