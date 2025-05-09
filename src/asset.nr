use dep::aztec::{prelude::AztecAddress, protocol_types::traits::{Deserialize, Packable, Serialize}};
use std::meta::derive;

#[derive(Deserialize, Packable, Serialize)]
pub struct Asset {
    pub oracle: AztecAddress,
    pub ltv: u128,
}