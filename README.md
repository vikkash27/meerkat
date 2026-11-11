# BS Detector

Meerkat watches the evidence while you watch the call. It sits on a Google Meet call without joining as a bot, transcribes both sides on-device, and checks public factual claims against the live web. A visible control window opens on launch, with start/stop, overlay rehearsal, transcript and Quit. A compact animated HUD shows checking activity, evidence confidence, sources and elapsed time. It checks public factual claims.

- **Ears:** ScreenCaptureKit captures system audio, which is the other person, and your microphone, which is you. With two people on the call, the two streams tell the speakers apart.
- **Transcript:** Apple's on-device `SpeechAnalyzer` runs one instance per speaker. Audio never leaves the Mac. Each finished sentence, plus a few lines of context, goes to OpenAI to look for claims, and only extracted claims go to Parallel.
- **Claims:** each finished sentence goes to OpenAI, which pulls out checkable facts. Small talk and opinions are skipped.
- **One-way:** only the other person (*Them*) is fact-checked; your own lines are context. To rehearse alone, enable **Also check me (solo test)** in the control window (or **Also Fact-check Me** in the 💩 menu). Name-drops count: "I met Muhammad Ali yesterday" is checked against the fact that he died in 2016.
- **Demo:** see [DEMO.md](DEMO.md) for the investor-pitch script.
- **Court:** a *prosecutor* and a *defender* each run their own [Parallel](https://docs.parallel.ai/search/search-quickstart) web search (one looking for evidence against the claim, one for evidence supporting it) and judge from those results. They run in parallel, and neither sees the other's answer. A claim is flagged only when the prosecutor calls it false or misleading with confidence of 0.7 or more **and** the defender concedes it can't be defended. No single agent can sign off on its own. Both judges also see the speaker's actual words as well as the extracted claim, so a question or a rebuttal isn't charged as a claim.
- **Show:** Vision positions animated brackets around faces in the Meet window. The big tile is *Them* and the self-view is *Me*; use **Swap Me / Them Faces** for side-by-side layouts. The silent, click-through HUD uses cyan for checking, coral for contradicted claims, mint for supported claims and neutral grey for unknowns. The evidence meter is a model estimate, not a calibrated probability of lying. Bottom call controls remain clear. **Show Transcript** opens the full receipts for review. **Test BS Burst** adds a clearly labelled rehearsal with playful emoji orbits.
- **Reliability:** only fetched URLs with usable excerpts can support a verdict; invented or missing citations remain unverified. Two sentence checks run at a time, with a bounded queue. Stopping cancels their requests. Parallel provides the two live searches; OpenAI extracts and assesses claims. The app does not currently call Parallel Decisions or Image Search.

## Run
```sh
./scripts/build-app.sh && open dist/BSDetector.app
```
1. In **Meerkat — Call Controls**, confirm **OpenAI Ready** and **Parallel Ready**, or click their buttons to add keys. The env vars `OPENAI_API_KEY` and `PARALLEL_API_KEY` also work.
2. Grant **Screen Recording** and **Microphone**, then relaunch after granting Screen Recording.
3. Join the Meet call in Chrome. The app finds the window titled "Meet – …"; otherwise use the control window's **Call window** picker and **Refresh**.
4. **Start Listening**. The first run downloads Apple's speech model.

Rehearse without a call or key: **Test overlay** in the control window (or **Test BS Burst** in the 💩 menu). Click the Dock icon or choose **Show Controls** to reopen the controls. **Quit Meerkat** and Command-Q stop the app. A second launch brings the existing app forward.

For this checkout, after building, `./scripts/run-local.sh` loads API keys from the ignored root `.env`, falling back to `web/.env`, then launches the app. Existing environment variables take precedence. Keys are never passed as command-line arguments. Do not commit either env file.

Solo test: with only you in the call, enable **Also check me (solo test)**, start listening and open the transcript. Your microphone appears as **Me** and is checked normally. Say “The Eiffel Tower was built in 1999,” then pause. For a large solo self-view, use **Swap faces** if the Me reticle is misplaced. The Them microphone path needs another participant's audio.

**Demo setup:** set the macOS default input to the same mic Meet uses, and keep other apps and tabs silent, because all system audio counts as *Them*. **Headphones are best.** If you're on speakers, untick **Wearing Headphones**. Your mic then also hears the other person, so a mic line that nearly copies what they said in the last 3 seconds is dropped as echo.

CLI: `swift run BSDetector --selftest` · `--transcribe file.aiff` · `--check "The Great Wall is visible from the Moon"` (needs both keys, and prints both court opinions and the timing).
Env: `BS_MODEL` (claim extraction) and `BS_JUDGE_MODEL` (prosecutor and defender) both default to `gpt-6-luna`; `BS_SEARCH_MODE` is the Parallel mode (`turbo`, `fast` (the default), or `advanced`). Extraction, search and judgment request timeouts are 8, 6 and 10 seconds respectively. Set `BS_AUTO_START=1` in the launching environment for optional automatic startup when Meet appears; otherwise use **Start listening**.

## Two-minute demo

1. Start listening with headphones, keeping other apps quiet. Allow the first speech-model download to finish before presenting.
2. Say: “Neon is the only hosted PostgreSQL platform that supports database branching.” Watch the checking brackets, Parallel research status and evidence meter.
3. Open **Show Transcript** to reveal the returned source and both independent opinions. Follow with “What makes your implementation different from the other branching platforms?”
4. Use **Test BS Burst** for a clearly labelled visual rehearsal. It makes no research request.

One live CLI run on 11 November 2026 checked the demo claim in 4.66 seconds including extraction (1.89 seconds). Both judges cited the fetched [Neon FAQ](https://neon.com/faqs/postgres-platforms-database-branching-git), which also names Supabase and Xata. This measured the text-to-evidence path; it did not include Meet transcription latency. Actual Meet capture and microphone permission still need a rehearsal on the presenting Mac.
