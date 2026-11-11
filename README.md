# BS Detector

Granola for bullshit. It sits on a Google Meet call without joining it as a bot, transcribes both sides on-device, and fact-checks what people say against the live web. When someone talks BS, 💩 and 🐂 burst out around their face in the call window.

- **Ears:** ScreenCaptureKit captures system audio, which is the other person, and your microphone, which is you. With two people on the call, the two streams tell the speakers apart.
- **Transcript:** Apple's on-device `SpeechAnalyzer` runs one instance per speaker. Audio never leaves the Mac. Each finished sentence, plus a few lines of context, goes to OpenAI to look for claims, and only extracted claims go to Parallel.
- **Claims:** each finished sentence goes to OpenAI, which pulls out checkable facts. Small talk and opinions are skipped.
- **Court:** a *prosecutor* and a *defender* each run their own [Parallel](https://docs.parallel.ai/search/search-quickstart) web search (one looking for evidence against the claim, one for evidence supporting it) and judge from those results. They run in parallel, and neither sees the other's answer. A claim is flagged only when the prosecutor calls it false or misleading with confidence of 0.7 or more **and** the defender concedes it can't be defended. No single agent can sign off on its own. Both judges also see the speaker's actual words as well as the extracted claim, so a question or a rebuttal isn't charged as a claim.
- **Show:** Vision finds the faces in the Meet window. The big tile is *Them* and the self-view is *Me*; use **Swap Me / Them Faces** for side-by-side layouts. A click-through overlay draws the burst, a "BULLSH💩T!" stamp and the correction. A Granola-style side panel shows the transcript, every check and its source link, and the 💩 score.

## Run
```sh
./scripts/build-app.sh && open dist/BSDetector.app
```
1. Open the 💩 menu → **Set OpenAI Key…** and **Set Parallel Key…**. The env vars `OPENAI_API_KEY` and `PARALLEL_API_KEY` also work.
2. Grant **Screen Recording** and **Microphone**, then relaunch after granting Screen Recording.
3. Join the Meet call in Chrome. The app finds the window titled "Meet – …"; otherwise pick it under **Call Window**.
4. **Start Listening**. The first run downloads Apple's speech model.

Rehearse without a call or key: **Test BS Burst**.

**Demo setup:** set the macOS default input to the same mic Meet uses, and keep other apps and tabs silent, because all system audio counts as *Them*. **Headphones are best.** If you're on speakers, untick **Wearing Headphones**. Your mic then also hears the other person, so a mic line that nearly copies what they said in the last 3 seconds is dropped as echo.

CLI: `swift run BSDetector --selftest` · `--transcribe file.aiff` · `--check "The Great Wall is visible from the Moon"` (needs both keys, and prints both court opinions and the timing).
Env: `BS_MODEL` (claim extraction) and `BS_JUDGE_MODEL` (prosecutor and defender) both default to `gpt-4.1-mini`; `BS_SEARCH_MODE` is the Parallel mode (`turbo`, `fast` (the default), or `advanced`).
