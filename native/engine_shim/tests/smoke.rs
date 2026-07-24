// Uses the library crate directly (not the C ABI) to prove runtime net
// loading works with the production nets.

use engine::composite::CompositeEvaluator;
use engine::position::Position;
use logic::wildbg_api::WildbgApi;

#[test]
fn loads_production_nets_and_evaluates_start() {
    // Build the CompositeEvaluator from the production nets at runtime, exactly
    // as wildbg_new_with_path does, then evaluate the starting position via the
    // same internal call path that `probabilities()` uses.
    let evaluator = CompositeEvaluator::from_file_paths_optimized(
        "../wildbg-nets/neural-nets/contact.onnx",
        "../wildbg-nets/neural-nets/race.onnx",
    )
    .expect("production nets should load from ../wildbg-nets/neural-nets");

    let api = WildbgApi::with_evaluator(evaluator);

    // Standard backgammon starting position in wildbg's 26-int pip encoding.
    let pips: [i32; 26] = [
        0, -2, 0, 0, 0, 0, 5, 0, 3, 0, 0, 0, -5, 5, 0, 0, 0, -3, 0, -5, 0, 0, 0, 0, 2, 0,
    ];
    let pips = pips.map(|pip| pip as i8);
    let position = Position::try_from(pips).expect("valid starting position");

    let probs = api.probabilities(&position);
    let win = probs.win_normal + probs.win_gammon + probs.win_bg;

    assert!(
        win > 0.4 && win < 0.6,
        "starting-position win probability out of expected range: {win}"
    );
}
