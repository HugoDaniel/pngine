
'use strict';

// CommonJS wrapper for browser bundle
// Note: This is for bundlers that don't support ESM

const browserModule = require('./browser.mjs');
module.exports = browserModule;
