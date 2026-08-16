//! Discovery hub for the cmd_validator test suite.
//!
//! The suite is split by error class, mirroring how the production code is
//! split (facade + params/validator/parse) rather than living in one 4,300-line
//! file. Every file must be listed here or its tests silently never run
//! (CONTRIBUTING §24) — importing a file elsewhere in the tree does not make
//! the compiler descend into its test blocks.
