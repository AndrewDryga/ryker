// Package evaluation replays recorded and live corpora through the same
// prompt and decision paths the runtime uses, and gates releases on the
// result. It sits above service the way app does: it may import service, and
// nothing imports it back.
package evaluation
