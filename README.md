# Meercat

A single meerkat in your menu bar. Drag it onto any app window, tell it what to do, and it watches that window and acts.

- **Watch:** every 4s it screenshots the window and asks OpenAI's **Decisions API** (`gpt-6-luna`) a yes/no question, such as "Has the build finished?". It needs two hits in a row at ≥80% before it acts.
- **Act:** it can notify you, press a shortcut (`cmd+s`, `return`, …) or type text into the window.
- **Plan:** the instruction you type is parsed once by the Responses API into `{condition, action, value, repeat}`. The screen can trigger the action but can never change it.

Examples:
- "When the export finishes, let me know"
- "When the tests go green, press cmd+w"
- "Every time a new message arrives, type 'on it' and press return"
- "Press cmd+r now" (no condition, so it runs immediately)

## Run
```sh
./scripts/build-app.sh && open dist/Meercat.app
```
Right-click the menu-bar icon → **Set OpenAI Key…** (stored in Keychain; `OPENAI_API_KEY` env also works).
Grant **Screen Recording**, plus **Accessibility** for keystroke and typing actions.

Click the icon → drag the meerkat onto a window → type an instruction → Enter.
Click the perched meerkat to show or hide its bubble; right-click it to remove it.

Env overrides: `OPENAI_MODEL` (planner, default `gpt-4.1-mini`), `OPENAI_DECISIONS_MODEL`.
Self-check: `swift run Meercat --selftest`.
