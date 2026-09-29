# Nimble Name — Specification

Nimble Name is a native macOS app that renames PDF and image files based on their content, using a vision-capable LLM reached through an OpenAI-compatible API. The local server is **oMLX** (MLX inference server for Apple Silicon, menu bar app + `omlx` CLI).

Status (2026-09-05): the SwiftUI app in `NimbleName/` builds and runs. The Go command-line prototype (`go-prototype/nameflow.go`) is kept for reference (section 9). The full pipeline (PDF → JPEG → oMLX → JSON) was verified with curl against `Qwen3.8-27B-8bit`.

## 0a. Local LLM server (oMLX)

| Item | Value on this Mac |
|---|---|
| Server | oMLX 0.6.4 (`/Applications/oMLX.app`, `omlx` via Homebrew), auto-starts at login |
| Base URL | `http://127.0.0.1:8008/v1` (port changed from oMLX's default 8000 in `~/.omlx/settings.json`) |
| API key | Not needed: key verification is skipped for localhost. Leave the API key field empty. |
| Models folder | `~/.omlx/models/<org>/<model>` — model id in the API is the folder name, e.g. `Qwen3.8-27B-8bit` |
| Admin UI | `http://127.0.0.1:8008/admin` (model downloader, aliases, settings) |
| JSON mode | `response_format: {type: json_schema, json_schema: {strict, schema}}` is honoured (constrained decoding). Plain `json_object` is **broken with thinking models** on 0.6.4: the reasoning leaks into the constrained output, e.g. `["date:"]` or `[{"_type": "thinking", ...}]`, and the real answer never comes. |
| Thinking | `/no_think` alone is **not** honoured by Qwen3.8 (reasoning still runs, lands in `reasoning_content`). `chat_template_kwargs: {enable_thinking: false}` does disable it. The app sends both when the "Disable model reasoning" setting is on. |

**Model recommendation (M5 Max, 128 GB, measured 2026-09-05)**

| Model (mlx-community) | Size | Vision | Per document | Notes |
|---|---|---|---|---|
| `Qwen3.8-27B-8bit` (installed) | 28 GB | native | 8–9 s warm, 19 s cold (measured) | Best accuracy (OmniDocBench 91.1), overkill for invoices |
| **`Qwen3.6-35B-A3B-8bit`** (recommended) | ~37 GB | native (MoE, 3B active) | est. 2–4 s | Newer generation than 3.5, roughly 3× faster than the 27B dense |
| `Qwen3.5-9B-8bit` | ~10 GB | native | est. 2–3 s | Smallest sensible choice; fine for key fields, weaker on hard or handwritten documents |

Prompt tokens per document are ~2,300 (image dominates), output ~50 tokens, so prefill speed (active parameters) matters more than decode speed. Keep `parallelRequests = 1`.

Install a model: oMLX admin → Models → download from Hugging Face, or

```bash
hf download mlx-community/Qwen3.6-35B-A3B-8bit --local-dir ~/.omlx/models/mlx-community/Qwen3.6-35B-A3B-8bit
```

then in Nimble Name → Settings → Model → Test Connection → Choose.

## 0. Project layout

| Path | Purpose |
|---|---|
| `NimbleName/NimbleName.xcodeproj` | Xcode project (single app target, synchronized source folder) |
| `NimbleName/NimbleName/NimbleNameApp.swift` | App entry: main window, Settings, History window, menu bar extra, menu commands, AppDelegate for opened files |
| `NimbleName/NimbleName/Info.plist` | Document types (PDF, images, folders) so files can be opened with the app; merged with the generated Info.plist |
| `NimbleName/NimbleName/AppModel.swift` | Central state: intake, analysis queue, renaming, undo, folder watching, notifications |
| `Models/ExtractedFields.swift` | The five fields returned by the model, normalization, amount splitting |
| `Models/DocumentItem.swift` | One review-table row (url, status, fields, custom name, rendered image) |
| `Models/RenameRecord.swift` | One rename for history/undo |
| `Services/AppSettings.swift` | All settings + defaults (prompt, template, endpoint...) persisted in UserDefaults |
| `Services/KeychainStore.swift` | API key storage |
| `Services/ImageRenderer.swift` | PDF page 1 / image → 1600 px JPEG (CoreGraphics + ImageIO, off the main actor) |
| `Services/LLMClient.swift` | OpenAI-compatible chat completions + `/models`, JSON extraction from the answer |
| `Services/FilenameComposer.swift` | Template → filename, sanitization, template → regex for matching and parsing |
| `Services/FolderAccess.swift` | Security-scoped bookmarks, grant panel, watched-folder flags |
| `Services/FolderWatcher.swift` | DispatchSource folder watching with 2 s debounce |
| `Services/HistoryStore.swift` | history.json persistence |
| `Views/ContentView.swift` | Main window, review table, thumbnails, status badges, empty state |
| `Views/PreviewView.swift` | Full-size preview sheet with editable filename and fields |
| `Views/SettingsView.swift` | Model / Prompt / Naming / Watching tabs |
| `Views/MenuBarView.swift`, `Views/HistoryView.swift` | Menu bar menu, history window |
| `NimbleName/scripts/generate_icon.swift` | CoreGraphics script that draws the app icon per *Nimble Icons style guide v2*: a cream dog-eared page with a Nimble Blue magic wand and two sparkles, on the family gradient `#009AD6` → `#006CA5`. Run `swift scripts/generate_icon.swift scripts/AppIcon.png` from `NimbleName/`, then `sips -z <n> <n> scripts/AppIcon.png --out NimbleName/Assets.xcassets/AppIcon.appiconset/AppIcon-mac-<n>.png` for 16, 32, 64, 128, 256, 512, 1024. `AccentColor` is `#009AD6` sRGB (matches the icon) |

Build from the terminal:

```bash
cd NimbleName && xcodebuild -project NimbleName.xcodeproj -scheme NimbleName -configuration Debug -derivedDataPath build build
```

---

## 1. Product decisions (agreed 2026-09-05)

| Topic | Decision |
|---|---|
| Name / identifier | **Nimble Name**, bundle identifier `pm.ad0.NimbleName` |
| Platform | Native macOS app, Swift 6 / SwiftUI, Xcode project. Minimum macOS 26. |
| App shape | Both: a regular window for review and settings, plus an optional menu bar icon with folder watching. |
| Renaming | Files are renamed **in place**. No output folder. |
| Confirmation | Review table first; nothing is renamed without a click. Names are editable inline and in the full-size preview. |
| Watch mode | Watched folders are analyzed in the background; results land in the review table and a notification says "N files ready to rename". |
| Model output | Structured JSON (date, vendor, description, currency, amount). Filename is built from an editable template. |
| Providers | OpenAI-compatible chat completions endpoint only (oMLX locally; LM Studio, Ollama or hosted endpoints also work). Base URL, model name, optional API key. |
| PDF pages | First page only. |
| Description language | Always English. |
| Vendor aliases | Not implemented (keep it simple). |
| Failures | Rows with an API error or an empty description are flagged and left unchecked. Never renamed automatically. |
| Missing vendor | Legitimate (handwritten notes, personal documents): the vendor segment is simply dropped from the name, e.g. `2024-01-08 - Handwritten meeting notes`. |
| Missing date | The app substitutes the file's creation date (falls back to modification date, then today). |
| Sandbox | App Sandbox on from day one. Folder access via security-scoped bookmarks. |
| Distribution | Notarized DMG first; App Store possible later (see section 8). |

---

## 2. User interface

### 2.1 Main window

- Toolbar: **Add files/folders**, **Analyze**, **Rename selected**, **Undo last batch**, watch-mode toggle, settings.
- Drop zone: the whole content area below the toolbar, whether it shows the empty state or the table. In the empty state a subtle dashed frame marks the zone permanently; while a drag hovers, the frame turns solid accent-coloured with a light tint (in both states). Implemented with `onDrop(of: [.fileURL])` and `NSItemProvider.loadItem(forTypeIdentifier: "public.file-url")`, not `dropDestination(for: URL.self)`: reading the `public.file-url` flavour at drop time is what gives the sandboxed app access to the file, and `dropDestination` did not accept PDF drags reliably. Each drop is logged under category `drop` with the pasteboard types it carried.
- Review table, one row per file (the individual fields are edited in the preview, not here):

  | Column | Notes |
  |---|---|
  | Checkbox | Checked by default when analysis succeeded with a description. |
  | Thumbnail | First page / image. Click or press **Space** opens the full-size preview. |
  | Source name | Read-only, full path on hover. |
  | Target name | Editable inline (extension shown, not editable). Typing a name that follows the template updates the fields; anything else is kept verbatim as a custom name. |
  | Status | Pending / Analyzing / Ready / Check (no description) / Error (message on hover) / Renamed / Skipped (reason shown in the target column). |

- Keyboard: arrow keys move between rows, Space toggles preview, Return starts editing, ⌘R renames selected.

### 2.2 Full-size preview

- Opened with Space or click on the thumbnail; behaves like Quick Look (Space or Esc closes, arrow keys move to previous/next file).
- Shows the rendered page or image at full size with zoom.
- Below the image: the **proposed filename as one editable text field**, plus the four structured fields. Editing either side updates the other. Purpose: copy extra information from the document (reference number, period, etc.) into the name.
- Buttons: **Rename this file**, **Skip**.

### 2.3 Menu bar

- Optional, enabled in settings. Icon shows a badge with the number of files ready for review.
- Menu: Open Nimble Name, Watching: on/off, list of watched folders, N files ready, Quit.
- "Launch at login" via `SMAppService`.

### 2.4 Settings window

**LLM**
- Base URL (default `http://127.0.0.1:8008/v1`, this Mac's oMLX port)
- API key (optional; stored in Keychain, never in plain text). Sent as `Authorization: Bearer …` when non-empty.
- Model name (default `Qwen3.8-27B-8bit`), with a **Choose** menu listing the models reported by the server after Test Connection
- Temperature (default `0.1`), Max tokens (default `512`), Timeout seconds (default `120`)
- **Test connection** button: calls `GET {base_url}/models`, reports success/failure and fills the Choose menu.

**Prompt**
- Multi-line editor for the prompt (default in section 4). **Reset to default** button.
- Toggle "Disable model reasoning" (default on; needed for Qwen3 models). Appends `/no_think` to the prompt and sends `chat_template_kwargs.enable_thinking = false` on the structured request.

**Naming**
- Filename template, default `{date} - {vendor} - {description} ({currency} {amount})`. **Reset to default** button.
- Rule: a parenthesized group whose placeholders are all empty is dropped entirely (so a document without amount becomes `2024-01-08 - Landlord - Rental contract`). An empty vendor drops its separator too (`2024-01-08 - Handwritten meeting notes`). The "already named" pattern treats the vendor segment as optional.
- Maximum filename length (default 120 characters, extension excluded).

**Watching**
- List of watched folders (added via open panel, each stored as a security-scoped bookmark). Remove button.
- Watched folders: ignore files whose name already follows the template (default on; never applies to manually added files, and names containing "Unknown" are never ignored).
- Show notification when files are ready (default on).
- Show menu bar icon (default on). Launch at login.

**Supported file types**: `.pdf .jpg .jpeg .png .heic .tif .tiff .webp`

---

## 3. Processing pipeline

1. **Intake**: files arrive by drop, open panel, folder watcher, or Finder "Open With" / Dock icon / `open -a "Nimble Name" file.pdf` (document types declared in `Info.plist`, handled by `AppDelegate.application(_:open:)`). Folders are walked recursively. Manually added files are **always analyzed**, even if their name already follows the template (the target then simply equals the source and stays editable). Anything that cannot be queued gets a **Skipped** row with the reason (unsupported type, sandbox denied access, empty folder). The watcher additionally ignores files whose name already follows the template (setting, default on) and skips silently. A name containing "Unknown" in any field never counts as "already named", so files produced by older prompts are re-analyzed. Every decision is logged to the unified log, subsystem `pm.ad0.NimbleName`, category `intake`:

   ```bash
   /usr/bin/log stream --level debug --predicate 'subsystem == "pm.ad0.NimbleName"'
   ```
2. **Access**: sandbox requires write access to the file's *parent folder* to rename. Dropped files grant access to the file only, so if the parent folder has no stored bookmark, the app shows an open panel pre-positioned on that folder asking to grant access once; the bookmark is then stored.
3. **Render**: PDFs → first page via `PDFKit` (`PDFPage.thumbnail(of:for:)` at ~1600 px on the long side). Images → downscaled to the same limit via `CGImageSource`. HEIC/TIFF/WebP converted to JPEG. Result encoded as a `data:image/jpeg;base64,…` URL.
4. **Query**: `POST {base_url}/chat/completions` with the prompt and image (see section 5). One request at a time by default (local models do not benefit from parallel requests); a "Parallel requests" setting (1–4) exists for hosted endpoints.
5. **Parse**: JSON object extracted from `message.content` (tolerating a ```json fence and surrounding text). "Unknown", "N/A", "none" and similar answers are treated as empty. Empty date → file creation date. Empty description → row status Warning, unchecked. Any parse failure → row status Error.
6. **Compose**: template → filename; empty fields are removed together with their separator (a doubled or dangling " - " is collapsed); parenthesized groups with only empty placeholders are dropped; sanitize (see section 6); collision check in the same folder → `_2`, `_3`, … suffix.
7. **Rename**: `FileManager.moveItem` within the same folder, wrapped in `NSFileCoordinator` so Finder and iCloud/kDrive see the change. Each batch is recorded for undo.
8. **Undo**: the last batch can be reverted from the toolbar; a History panel lists every rename with a per-row Revert.

Watcher: `DispatchSource` on the folder file descriptor, **top level only** (subfolders of a watched folder are not watched). Events are debounced 2 s; a file is only picked up once its size is unchanged over 2 s, so files still being written by a scanner are not analyzed half-way. Unstable files are re-checked 5 s later. Files renamed by the app are remembered for the session and not re-analyzed.

Full-name editing in the preview: the typed name is parsed back into fields with the template regex when it round-trips exactly; otherwise it is kept verbatim as a custom name (sanitized at rename time) and the fields are ignored until one of them is edited.

---

## 4. Default prompt

```
You are a document analysis assistant. Look at the provided document image and extract the following fields. Reply with a single JSON object and nothing else.

{
  "date": "YYYY-MM-DD, or empty string if the document shows no date",
  "vendor": "issuing organisation or company exactly as printed, or empty string",
  "description": "concise English sentence-case phrase describing what the document is",
  "currency": "ISO 4217 code such as CHF, EUR, USD, or empty string",
  "amount": "total or amount due exactly as printed, digits with decimal point, or empty string"
}

Rules:
- date: prefer the invoice/statement date. Leave empty if no date is printed. Never guess.
- vendor: the sender/issuer (e.g. "SBB", "Swisscom", "Migros Genf"). Keep the printed capitalization. Do not normalize. Leave empty for documents without an issuing organisation, such as handwritten notes, personal letters or photos.
- description: always in English, first word capitalized, rest lowercase, no jargon or repetition (e.g. "Mobile phone bill", "Handwritten meeting notes", "Rental contract"). Never leave it empty.
- currency and amount: only if a total or amount due is clearly stated. Never invent a value. Leave both empty otherwise.
- Never use colons, slashes or backslashes inside any value. Never write "Unknown"; use an empty string instead.
```

`/no_think` is appended on a new line when the "Disable model reasoning" setting is on. Users who edited the prompt before this change can restore it with **Reset to Default Prompt** in Settings → Prompt.

## 5. API request

```json
{
  "model": "<model name>",
  "temperature": 0.1,
  "max_tokens": 512,
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "document_fields", "strict": true,
      "schema": { "type": "object", "additionalProperties": false,
                  "required": ["date", "vendor", "description", "currency", "amount"],
                  "properties": { "date": {"type": "string"}, "vendor": {"type": "string"},
                                  "description": {"type": "string"}, "currency": {"type": "string"},
                                  "amount": {"type": "string"} } }
    }
  },
  "chat_template_kwargs": { "enable_thinking": false },
  "messages": [
    { "role": "user", "content": [
      { "type": "text", "text": "<prompt>\n/no_think" },
      { "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,..." } }
    ] }
  ]
}
```

The first attempt is the **structured** request above (`response_format` with a strict schema, plus `chat_template_kwargs` when reasoning is disabled). It is retried once as a **plain** request, without either field, when:

- the server answers HTTP 400 (endpoint rejects `response_format` or `chat_template_kwargs`, e.g. hosted OpenAI), or
- the answer contains no JSON object with at least one of the five keys (`LLMError.noJSON`). This is the oMLX `json_object` failure mode where the model's reasoning leaks into the constrained output.

In plain mode a thinking model reasons first (slower, ~160 tokens instead of ~40) and then answers in `content`; the parser extracts the first `{...}` object from the text. Errors surface as the row's Error status with the HTTP status and the first 200 characters of the body, or "Model answer is not JSON: …" when both attempts fail.

Measured on 2026-09-07 with `Qwen3.8-27B-8bit` on a synthetic handwritten note: `json_object` → garbage (thinking array), `json_schema` → correct answer in 37 completion tokens / 10 s, plain → correct answer in 163 tokens / 32 s.

---

## 6. Filename sanitization

- Replace `\ / : * ? " < > |` with a space; collapse runs of whitespace; trim.
- Strip leading dots (hidden files) and trailing spaces/dots.
- Truncate to the configured maximum length (default 120) without cutting inside a multi-byte character, then re-append the original extension in lowercase.
- Empty result → fall back to the original name and mark the row Error.

---

## 7. Storage

| Data | Where |
|---|---|
| Settings, prompt, template | `UserDefaults` (app group not needed) |
| API key | Keychain |
| Folder bookmarks | `UserDefaults` as security-scoped bookmark data |
| Rename history | JSON file in `~/Library/Application Support/Nimble Name/history.json` (last 1000 entries) |

---

## 8. Build and distribution

- Xcode project `NimbleName/NimbleName.xcodeproj`, single app target, Swift 6 strict concurrency, no third-party packages.
- Entitlements: `com.apple.security.app-sandbox`, `com.apple.security.network.client`, `com.apple.security.files.user-selected.read-write`, `com.apple.security.files.bookmarks.app-scope`.
- Bundle identifier `pm.ad0.NimbleName`, product name "Nimble Name", module name `NimbleName`.
- Build settings of note: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`; model/service types are declared `nonisolated`, rendering runs `@concurrent`.
- Info.plist extras: `ITSAppUsesNonExemptEncryption = NO` (skips the export-compliance question on every upload), `NSAppTransportSecurity.NSAllowsLocalNetworking = YES` (macOS 14+ ATS blocks plain-HTTP connections to IP addresses by default; loopback worked without it, LAN addresses such as `http://10.x.x.x:8008` need it). `PrivacyInfo.xcprivacy` declares no tracking, no collected data, and the UserDefaults (CA92.1) and file-timestamp (DDA9.1) required-reason APIs; not mandatory on macOS but harmless.
- Two distribution paths:
  - **Direct / DMG**: `scripts/release.sh` (Developer ID, notarized, `scripts/ExportOptions.plist`).
  - **Mac App Store**: `scripts/appstore.sh` archives and exports a `.pkg` into `dist/appstore/` with `scripts/ExportOptions-AppStore.plist` (method `app-store-connect`, automatic signing, team `5U2JDBY88V`). `--upload` uploads with the Apple ID signed in to Xcode; otherwise use Transporter or Xcode's Organizer.
- App Review notes: the app is useless without a reachable OpenAI-compatible server, and reviewers have no oMLX. Give them a hosted endpoint + API key in the review notes (any OpenAI-compatible vision model), and explain that the default configuration targets a local server on the user's Mac. A privacy policy URL is mandatory in App Store Connect; the honest nutrition label is "Data Not Collected" (documents go only to the server the user configures).
- Views reach the model through `AppModel.shared`, not `@Environment(AppModel.self)`. On macOS 27 beta the environment lookup failed nondeterministically in separately hosted views (toolbar / menu bar) and crashed with "No Observable object of type AppModel found". Observation tracking works the same with the shared instance.
- Signing: Automatic, team `5U2JDBY88V` (Developer ID Application certificate in the login keychain).
- Release pipeline: `NimbleName/scripts/release.sh` archives, exports with Developer ID (`scripts/ExportOptions.plist`), notarizes app and DMG with `notarytool` (keychain profile `NimbleName-notary`, created once with `xcrun notarytool store-credentials`), staples, and writes `NimbleName/dist/NimbleName-<version>.dmg` containing the app, an Applications symlink and a short read-me about the model server. `--no-notarize` skips the Apple round-trip for a local check. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in the project before a release.
- Release: Developer ID signing + notarization, packaged as DMG (see pipeline above).
- App Store: technically compatible (sandboxed, no private API). Review risk: the app is non-functional without a running local model server. Mitigation is to document a hosted OpenAI-compatible endpoint in the review notes.
- Toolchain: Xcode 27 beta is the active developer directory (`xcode-select -p`).

---

## 9. Legacy Go prototype (`go-prototype/`)

Kept for reference until the Swift app reaches parity. Headless, no dependencies. All files (`nameflow.go`, `go.mod`, the prebuilt `nameflow` binary, `config.yaml`, `prompt.txt`, `inputs/`, `outputs/`) live in `go-prototype/`; run it from that folder so the relative paths in `config.yaml` resolve.

- Config in `config.yaml` (flat keys only: `input_folder`, `output_folder`, `base_url`, `model_name`, `temperature`, `timeout_seconds`).
- Prompt in `prompt.txt`, returns the final filename string directly (not JSON).
- PDFs rendered with `sips` (first page). Files are **moved** to the output folder.
- Recommended model in LM Studio: **Qwen3-35B-A3.5B MoE** (~3.5B active parameters, 2–3× faster than the 27B dense model on M-series Macs; quality sufficient for date/vendor/amount extraction). This recommendation carries over to the Swift app.
- Filename format produced by the prompt: `YYYY-MM-DD - Vendor - Description (CURRENCY amount)`.
