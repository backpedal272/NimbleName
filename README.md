# Nimble Name

**Rename PDFs and images from their content, using a vision LLM that runs on your own Mac.**

Nimble Name reads each document, works out what it is, and suggests a name with the date, the sender, a short description and the amount. Nothing is renamed until you confirm, and a whole batch can be undone in one click.

| Before | After |
|---|---|
| `Scan_0042.pdf` | `2026-03-14 - Swisscom - Mobile phone bill (CHF 49.90).pdf` |
| `IMG_7731.jpg` | `2026-05-02 - Migros - Grocery receipt (CHF 87.35).jpg` |
| `document(3).pdf` | `2026-01-08 - Handwritten meeting notes.pdf` |

> Free and open source (GPL-3.0). Part of [Nimble Apps](https://nimbleapps.ch).

## Features

- **Drop, review, rename.** Drag in files or folders, check the suggested names, edit any of them, then rename.
- **Local and private.** Uses a model on your own Mac through an OpenAI-compatible API. Your documents don't leave the machine unless you point it at a remote service.
- **Watched folders.** Point it at Downloads or a scanner folder. New files are analysed in the background, with a notification when they're ready.
- **Your naming pattern.** Change the pattern, edit suggestions, or add a reference number from the full-size preview.
- **Handles messy input.** Invoices, receipts, contracts, letters, handwritten notes and phone photos.
- **Menu bar icon** showing how many files are waiting.
- **Undo history** for every batch.

Supported files: PDF, JPG, PNG, HEIC, TIFF and WebP.

## Requirements

- A Mac with Apple Silicon running macOS 26 or later
- A local LLM server with a vision model, such as oMLX, [LM Studio](https://lmstudio.ai) or [Ollama](https://ollama.com). Any OpenAI-compatible endpoint works. Set its address and model in Settings.

## Install

Nimble Name is in beta. [Join the beta on TestFlight](https://testflight.apple.com/join/u4wDxvSU). It's free. More on [nimbleapps.ch](https://nimbleapps.ch/nimblename/index.html).

## Build from source

You need Xcode.

```sh
git clone https://github.com/backpedal272/NimbleName.git
cd NimbleName
open NimbleName/NimbleName.xcodeproj
```

Then choose **Product › Run**. To run it signed on your own Mac, pick your team under **Signing & Capabilities**.

## Project layout

| Path | Contents |
|---|---|
| `NimbleName/NimbleName/` | SwiftUI app: LLM client, folder watcher, filename composer, history, views |
| `NimbleName/scripts/` | Release and App Store build scripts, icon generator |
| `NimbleName-specs.md` | Product specification |
| `go-prototype/` | The original command-line prototype in Go |

## Contributing

Bug reports and suggestions are welcome in [Issues](https://github.com/backpedal272/NimbleName/issues). Contact: info@nimbleapps.ch.

## License

GPL-3.0. See [LICENSE](LICENSE).

Suggested names come from a language model and can be wrong. Review them before renaming.
