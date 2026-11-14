# Live workspace update

The studio opens at the latest evidence and renders new transcript events immediately. The replay scrubber is removed from the agent screen. Code no longer uses the dissolve/scan shaders or a moving camera. The top panel retains the latest complete agent message while files, commands, test results and pictures change below it; longer text scrolls and supports selection.

The work-surface picker includes the workspace, remote browser/game desktop, agent screenshots and project preview. Follow switches surfaces on real transcript hints; choosing a surface manually disables Follow so logging in is not interrupted by the next event. Desktop Control takes one tap, with typing, paste, Tab, Enter and Escape available in full screen too. The display picker lists browser and Xvfb/game displays. `DISPLAY=:N` in a command selects that display; otherwise browser tools use the shared desktop. A headless browser or headless game has no visible desktop to stream. Screenshots appear only when the agent actually captures/opens them. This cannot stream a native iOS simulator from Linux.

New tasks default to the saved **Unattended · no approvals** choice. Claude uses `--dangerously-skip-permissions`, Codex uses `--dangerously-bypass-approvals-and-sandbox`, Gemini uses `--approval-mode yolo`. This permits commands and edits across the machine, including outside the project. The picker still offers asking, edit acceptance and planning/read-only modes. The API retains its asking default for existing clients. Running sessions keep the mode they started with; login, account trust, enterprise policy and human questions may still require input. No prompt auto-clicker was added.

## Tokens

Musa launches the installed agent CLI in tmux. It does not call a model to render the studio, summarize progress or drive the UI. Transcript reads, file requests, screenshots displayed on the device and VNC traffic add network/CPU work, but no model tokens. The same CLI, model, configuration, prompt and history should therefore have comparable model usage over Musa and SSH. This is an architectural comparison, not a measured claim of equal billing per run. Agent decisions, tool output, image input, retries and resumed context can change usage. Images explicitly sent to the agent still count as normal model input. No token savings are claimed.

## Verification

The gateway tests exercise actual tmux launches with capture-only fake CLIs, checking all three unattended modes, literal shell-safe prompts, and the unchanged API default. UI coverage checks a persistent narration panel, absence of the scrubber and switching to the desktop in both iPad orientations. iOS compilation and simulator rendering require the macOS GitHub runner; this Linux host cannot validate those locally.
