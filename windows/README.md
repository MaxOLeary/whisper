Windows tray dictation. Python 3.12 or newer. Hold Alt+Space, speak, release. It pastes with Ctrl+V and puts the old clipboard back.

The speech engine is whisper.cpp v1.9.5 from ggml-org (the pin is `PIN.txt`). The v1.9.5 GitHub release has no Windows zip, so the first run downloads that tag and compiles `whisper-cli.exe`. Install CMake and the Visual Studio 2022 Build Tools workload "Desktop development with C++" before the first run. The model `ggml-tiny.en.bin` downloads from `ggerganov/whisper.cpp` on Hugging Face. Both land in `%USERPROFILE%\.config\whisper\windows\`. The Mac file `%USERPROFILE%\.config\whisper\config.json` is never opened.

Do not install sherpa-onnx. This app does not use it.

```bat
cd whisper
py -3 -m venv windows\.venv
windows\.venv\Scripts\python -m pip install -r windows\requirements.txt
windows\.venv\Scripts\python windows\app.py --check
windows\.venv\Scripts\python windows\app.py
```

`--check` has to print `CHECK OK`. The first one compiles whisper.cpp, so give it several minutes. A microphone has to be allowed. `RECORDING SKIP` means Windows blocked the mic. `RECORDING OK` with a blank transcript is silence, which still counts as the tool running.

Then `windows\app.py` with no arguments leaves a tray icon. Alt+Space records. Meeting mode is not in this build: `--meeting` exits 2. There is no installer exe.

PySide6 is Qt (Finland). sounddevice is Matthias Geier (Germany). numpy is NumPy.
