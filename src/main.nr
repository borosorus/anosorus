/*
    Could add a smart wallet try to repay function, to avoid liquidations, with incentive for liquidators

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
// TODO OVERFLOOOOWW
#[aztec]
pub contract Lending {
    use dep::aztec::prelude::{AztecAddress, Map, PublicMutable, PublicImmutable};

    use crate::loan::Loan;
    use crate::balance::Balance;
    use crate::asset::Asset;
    use dep::price_feed::PriceFeed;
    use dep::token::Token;

    use dep::aztec::macros::{
        functions::{initializer, internal, private, public, view},
        storage::storage,
    };

    use dep::aztec::protocol_types::traits::{FromField, ToField};
    use dep::aztec::hash::compute_secret_hash;

    // Storage structure, containing all storage, and specifying what slots they use.
    #[storage]
    struct Storage<Context> {
        // Public Immutables
        base_token: PublicImmutable<AztecAddress, Context>,

        // Public Mutables
        reserve_fee: PublicMutable<u128, Context>,
        admin: PublicMutable<AztecAddress, Context>,

        collaterals: Map<AztecAddress, PublicMutable<Asset, Context>, Context>,
        collateral_is_active: Map<AztecAddress, PublicMutable<bool, Context>, Context>,

        loans: Map<Field, PublicMutable<Loan, Context>, Context>, // secret based loan
        loan_exists: Map<Field, PublicMutable<bool, Context>, Context>,

        total_debt: PublicMutable<u128, Context>,
        current_index: PublicMutable<u128, Context>,
        last_update_ts: PublicMutable<u64, Context>,
        available_base: PublicMutable<u128, Context>,
        reserve: PublicMutable<u128, Context>,
        balances: Map<Field, PublicMutable<Balance, Context>, Context>, // secret based balance, only public
    }

    #[public]
    #[initializer]
    fn constructor(base_token: AztecAddress) {
        assert(!base_token.is_zero(), "invalid base");

        storage.base_token.initialize(base_token);

        storage.admin.write(context.msg_sender());

        storage.reserve_fee.write(15000000); // 15% on interests
        storage.current_index.write(100000000); // Initialize debt index at 1
        storage.last_update_ts.write(context.timestamp()); // Initialize ts now
    }

    /*
        ADMIN
    */

    #[public]
    fn add_collateral(address: AztecAddress, oracle: AztecAddress, ltv: u128) {
        assert(context.msg_sender() == storage.admin.read());
        let collateral = Asset { oracle: oracle, ltv: ltv };
        storage.collaterals.at(address).write(collateral);
        storage.collateral_is_active.at(address).write(true);
    }

    #[public]
    fn set_collateral_state(address: AztecAddress) {
        assert(context.msg_sender() == storage.admin.read());
        let collateral_state_slot = storage.collateral_is_active.at(address);
        collateral_state_slot.write(!collateral_state_slot.read());
    }

    /* 
        PUBLIC
    */

    #[public]
    fn accrue_interest() -> u128 {
        let current_ts = context.timestamp();
        let delta = current_ts - storage.last_update_ts.read();
        let mut current_index = storage.current_index.read();

        if delta > 0 {
            let total_debt = storage.total_debt.read();

            let UNIT: u128 = 100000000;
            let BASE_RATE: u128 = 100000000;

            // TODO COMPUTE A BORROW RATE
            let borrow_rate_per_second = BASE_RATE * ((total_debt * UNIT) / (total_debt + storage.available_base.read()));
            //TODO 

            let interest_factor = borrow_rate_per_second * delta as u128;

            storage.total_debt.write(total_debt + (interest_factor * total_debt) / UNIT);
            current_index = current_index + (current_index * interest_factor) / UNIT;

            storage.current_index.write(current_index);
            storage.last_update_ts.write(current_ts);
        }

        current_index
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

    /*
        INTERNAL
    */

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
        let current_index = Lending::at(context.this_address()).accrue_interest().call(&mut context);

        let loan_slot = storage.loans.at(loan_id);
        let mut loan = loan_slot.read();

        loan.debt = (loan.debt * current_index) / loan.last_index - debt;

        if(collateral.to_field() != 0) {
            assert(loan.collateral == collateral);

            loan.collateral_amount -= collateral_out_amount;
            if(loan.debt > 0) {
                assert(check_loan(&mut loan, &mut storage.collaterals.at(collateral).read()));
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
        assert(storage.collateral_is_active.at(collateral).read());
        assert(base_token == storage.base_token.read());

        let current_index = Lending::at(context.this_address()).accrue_interest().call(&mut context);

        let loan_exists = storage.loan_exists.at(loan_id).read();

        if(loan_exists) {
            let loan_slot = storage.loans.at(loan_id);
            let mut loan = loan_slot.read();

            assert(loan.collateral == collateral);

            loan.debt = ((loan.debt * current_index) / loan.last_index) + debt_amount;
            loan.collateral_amount += collateral_amount;

            assert(check_loan(&mut loan, &mut storage.collaterals.at(collateral).read()));

            loan_slot.write(loan);

        } else {
            let mut loan = Loan {collateral: collateral, collateral_amount: collateral_amount, debt: debt_amount, last_index: current_index};

            assert(check_loan(&mut loan, &mut storage.collaterals.at(collateral).read()));
            storage.loans.at(loan_id).write(loan);
            storage.loan_exists.at(loan_id).write(true);
        }

        storage.available_base.write(storage.available_base.read() - debt_amount); // TODO check not more than available ? or fails if not
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

        let current_index = Lending::at(context.this_address()).accrue_interest().call(&mut context);
        Lending::at(context.this_address())._update_balance(user_id, current_index, amount, 0).call(&mut context);
    }

    #[public]
    #[internal]
    fn _withdraw(
        base_token: AztecAddress,
        amount: u128,
        user_id: Field, 
    ) {
        assert(base_token == storage.base_token.read());

        let current_index = Lending::at(context.this_address()).accrue_interest().call(&mut context);
        Lending::at(context.this_address())._update_balance(user_id, current_index, 0, amount).call(&mut context);
    }

    #[contract_library_method]
    fn check_loan(
        loan: &mut Loan
        collateral_asset: &mut Asset
    ) -> bool {
        let UNIT: u128 = 100000000;

        let collateral_price = PriceFeed::at(collateral_asset.oracle)
            .get_price(loan.collateral.to_field()).view(&mut context).price;
        
        (loan.debt * UNIT) / (loan.collateral_amount * collateral_price) > collateral_asset.ltv
    }

    #[public]
    #[internal]
    fn _update_balance(
        user_id: Field,
        current_index: u128,
        to_add: u128,
        to_sub: u128,
    ) {
        let UNIT: u128 = 100000000;

        let balance_slot = storage.balances.at(user_id);
        let mut balance = balance_slot.read();
        let mut current_balance = if balance.amount > 0 {(balance.amount * current_index) / balance.last_index } else {0};

        let reserve_fee = (storage.reserve_fee.read() * (current_balance - balance.amount)) / UNIT;

        current_balance = current_balance + to_add - reserve_fee;

        assert(current_balance >= to_sub);
        current_balance -= to_sub;

        balance.amount = current_balance;
        balance.last_index = current_index;

        storage.available_base.write(storage.available_base.read() + to_add - to_sub);
    }

}