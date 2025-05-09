use dep::aztec::{prelude::AztecAddress, protocol_types::traits::{Deserialize, Packable, Serialize}};
use std::meta::derive;

#[derive(Deserialize, Packable, Serialize)]
pub struct Loan {
    pub collateral: AztecAddress,
    pub collateral_amount: u128,
    pub debt: u128,
    pub last_index: u128,
}