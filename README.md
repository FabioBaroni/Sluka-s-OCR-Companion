# Sluka’s OCR Companion

**Use your Sluka dictionaries and vocabulary grades wherever you read on your Mac.**

Sluka already lets you look up words and track vocabulary in your browser. I built Companion to bring that workflow to other Mac apps. Read a PDF in Preview, look up a word in a screenshot, study subtitles in a video player, or try reading dialogue in a game window that macOS can capture.

Point at a word or capture a passage. Companion reads selectable text or uses local OCR, then sends the text to Sluka through a local Chrome reader tab. A floating card shows definitions from the dictionaries installed in Sluka, along with each word’s current Sluka grade. **Click a grade in Companion and the change is saved in Sluka.** The reader tab can stay open in the background while you keep reading.

Created by **Fabio Baroni (pentestguru)**. This is an independent community project and is not affiliated with or endorsed by Sluka.

## Read and update your Sluka vocabulary

1. **Capture or select text.** Companion gets the text from the app or recognizes it from the screen.
2. **Look up a word.** Select it in the floating card to see the definition and current vocabulary grade from Sluka. The card highlights the characters or word you’re looking up.
3. **Update the grade.** Click **Unknown**, **1–4**, **Known**, or **Ignore** in the card. Companion sends the change to Sluka and updates the displayed grade when Sluka confirms it. When you look up the same entry in Sluka, you’ll see the updated grade there too. Any sync you’ve enabled in Sluka applies as usual.

**Unknown** resets the entry to Sluka’s **New** status. Click the floating card once to use the single-key shortcuts `U`, `1`–`4`, `K`, and `I`. Some dictionary entries show a definition without offering a grade control.

## What you can do

| What you’re reading | What to do |
| --- | --- |
| Selectable text in a browser, document, or other app | Highlight the text and click the eye beside it, or press **Control–Option–L**. |
| A word on screen | Point at it and press **Control–Option–L**, or turn on **Automatic Hover** in the menu bar. |
| Text inside an image, video frame, scanned page, or capturable game window | Choose **Capture Screen Area** and drag around the text you want to read. |
| Text across a whole app window | Choose **Capture Window** and pick a window. The card opens in the center of its display and filters OCR results by study language. |

Use **Other matches**, when available, to try a different word boundary. Use **Translate selection** to translate the displayed passage, or **Captured passage** in longer captures to switch between sections. You can also pin the card, copy the captured text, and adjust the card’s text size in **Settings**.

## Languages and screen capture

The **Study Language** menu includes all of Sluka’s built-in languages. Choose the same study language in both apps. Companion uses the dictionaries installed in Sluka for definitions in that language.

Screen OCR runs locally using Apple Vision or Live Text. Companion can also use an existing Homebrew Tesseract installation with the matching language data. OCR availability varies by language and Mac. **Image word picker** means you choose a word from recognized text. **Selectable text only** means lookup uses Accessibility. Whole-window filtering can keep short or mixed-language lines when the language is uncertain.

For games and video, start with **Capture Screen Area** around the dialogue or subtitle. Capture depends on whether macOS can read that part of the screen and whether the lettering is clear enough for OCR.

## Requirements

- **macOS 15 Sequoia or later** on an Apple Silicon or Intel Mac.
- **Google Chrome** with the Sluka extension installed and enabled in the Chrome profile you use for the reader. [Install Sluka from the Chrome Web Store](https://chromewebstore.google.com/detail/sluka/olobfjbmcfjhkdlcpcklaohoofjbegio).
- **Accessibility** permission for reading selectable text and **Screen Recording** permission for reading text from screen pixels. Grant both to let Companion switch between reading methods automatically.

## Install the GitHub release

1. In this repository’s **Releases** tab, download the ZIP containing the prebuilt Mac app from the release’s **Assets**.
2. Quit any previous copy of Companion. Unzip the download and drag **Sluka’s OCR Companion.app** into **Applications**.
3. In **Applications**, double-click the app. Look for the eye-shaped magnifier in the macOS menu bar.

### If macOS asks you to confirm the first launch

The release uses an ad-hoc signature and has no Apple notarization. This can trigger a developer-verification warning on first launch. If you downloaded the app from this repository’s **Releases** page and trust the download, open **System Settings → Privacy & Security**, select **Open Anyway** for Companion, and confirm. macOS remembers that choice for the app. [Apple’s first-launch guidance](https://support.apple.com/en-us/102445).

### First-time setup

1. In Companion’s setup window, choose **Allow Accessibility** for selectable text and **Allow Screen Recording** for OCR from windows and images. Complete the macOS prompts and reopen Companion if macOS asks. You can revisit either permission from **menu bar icon → Settings… → Review Permissions…**.
2. Choose your language under **Study Language** and select the same language in Sluka.
3. Highlight a sentence and press **Control–Option–L**. The first lookup opens a local reader tab in Chrome. Leave it open in the profile with Sluka installed. If prompted, choose **Activate Sluka here** from Sluka’s extension menu on that tab.
4. Click a word in the floating card for its definition and grade. Try changing its grade from the card, or click **Translate selection** to translate the whole passage.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Look Up Selection or Pointer | `⌃⌥L` |
| Toggle Automatic Hover | `⌃⇧H` |
| Capture Screen Area / Capture Window | `⌃⇧A` / `⌃⇧W` |
| Connect or show Sluka Reader | `⌃⇧S` |
| Translate selection | `⌃⇧T` |
| Previous / next word | `⌃⇧B` / `⌃⇧N` |
| Copy captured text | `⌃⇧C` |
| Pin / unpin card | `⌃⇧P` |
| Close card | `⌃⇧D` |

## If a lookup doesn’t work

- **The card can’t connect to Sluka.** Choose **Connect Sluka…** from the menu bar and check that Sluka is enabled on the reader tab and set to the same study language.
- **A definition is missing.** Use **Retry Lookup** in the card when available. If Sluka’s word preview is disabled, enable **Hover preview** in Sluka’s settings.
- **The whole-window capture missed part of the text.** Use **Capture Screen Area** around the exact passage. This also works when you want to keep text in multiple languages.
- **A translation is missing.** Check your translation settings in Sluka and try **Retry translation**. You can also open the Sluka reader from the card and select the passage there.

## Privacy

Companion recognizes screen text on your Mac and passes the captured text to the local Chrome reader tab. Sluka handles dictionary lookups, grades, and translations. Your Sluka settings determine whether text is sent to a translation provider. [Sluka’s privacy policy](https://sluka.app/privacy).

## Build from source (optional)

Use the Xcode Command Line Tools with a macOS 26 SDK. The app runs on macOS 15 and later. The test suite also requires Node.js.

```sh
zsh build.sh
zsh Tests/run.sh
```

The build produces a universal app at `Build/Sluka's OCR Companion.app`.

## Credits and licenses

- **Sluka’s OCR Companion** by Fabio Baroni (pentestguru), [MIT license](Licenses/OCR-Companion.txt).
- Based on [LongYan Reader](https://github.com/mapuchuu/longyan-reader) by mapuchuu, [MIT license](Licenses/Longyan-Reader.txt).
- The bundled [CC-CEDICT data](Licenses/CC-CEDICT.md) helps identify Chinese word boundaries. The definitions shown in the card come from Sluka.
