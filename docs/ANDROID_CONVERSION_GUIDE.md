# Android conversion and support

Open the main drawer → Conversion settings. The default **Offline** mode reads and narrates imported Firebrat packages without signing in or contacting a server. Import an existing `.tar.gz` package from the library; choosing a PDF instead requires a conversion mode.

## Convert entirely on the phone

1. Choose **On-device** in Conversion settings.
2. Choose **Illustrated / technical** for figures and formulas, or **Novel / characters** for character narration. Check the male/female voice choices and any character overrides before conversion.
3. Select a local LLM and download its model while connected. Start with the smallest supported quantized model on phones with limited memory. Larger models can be slower or run out of memory; consult the measured results in [offline device testing](OFFLINE_DEVICE_TESTING.md).
4. Select the system narrator or **Kokoro** and a voice. Download Kokoro voice data before disconnecting. System voices may also require an offline language pack in Android's speech settings.
5. Turn **cloud fallback off** for completely local processing. Choose a short PDF first and start conversion. Keep the app available and allow its conversion notification; lengthy books need battery, free storage and time.
6. Open the completed book, inspect figure placement against Source page, and listen to several sections. Character identification and generated narration need review, especially with small models. Scanned PDFs depend on OCR quality.
7. Test again with networking disabled after downloading the required assets. Imported books remain playable without the conversion models.

## Convert on a computer and read on the phone

1. Install the [guided Firebrat server](../installer/server/README.md) from the GitHub release, or use the documented CPU/NVIDIA Docker setup. Complete model downloads on the computer first. An LLM API is optional; voice generation stays on the computer.
2. Use the server's desktop page to select the PDF, book type, LLM and narrator. Start with a few pages, then inspect the resulting audio and figures before converting a whole book.
3. Put the phone and computer on the same trusted network, or use the guide's Tailscale setup for private remote access. Enter the reachable server URL in the app's **Server** settings; `localhost` on the phone refers to the phone itself. Keep authentication enabled and do not expose an unauthenticated conversion server to the public internet.
4. Sign in when the configured server requires it. Upload from the app or convert through the desktop page; refresh Server library, then download the completed book.
5. Open the downloaded book and test in airplane mode. The server is needed for conversion and downloads, but completed local books do not require it for playback.

## Report a problem

Use [GitHub bug reports](https://github.com/Subhajit-Roy-Partho/firebrat/issues/new?template=bug_report.yml). Include app version, device/Android version, conversion mode, LLM, narrator, steps, exact error and whether networking was disabled. For figure problems, include the PDF page and corresponding section. Attach only books you can legally share, and remove credentials and personal data from logs.
