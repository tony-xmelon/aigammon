// Smoke script for `firebase emulators:exec --only functions`: if the exec
// wrapper reaches this, the functions emulator parsed and loaded the compiled
// lib/index.js (all exports/imports resolve). See Task 2 of the online-play plan.
console.log('functions loaded');
