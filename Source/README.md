# Sluka's OCR Companion 3.11.11 beta

A Mac menu bar multilingual reader based on [LongYan Reader](https://github.com/mapuchuu/longyan-reader). Highlight a passage to get the LongYan selection button and a native card. Use Sluka grades from that same card.

Created by Fabio Baroni (pentestguru). This is an independent community project. It is not affiliated with or endorsed by Sluka.

## Open and read

1. Extract the ZIP, quit the previous version if it is running, and open **Sluka's OCR Companion.app**. The app lives in the menu bar under the eye-shaped magnifier icon.
2. Choose your study language from the eye menu. Highlight text and click the eye beside it. You can also point at text and press **Control + Option + L**, or enable **Automatic Hover** and pause over a word. When the OCR engine locates only a line or region, choose a word in the card.
3. The first-use setup shows **Accessibility** for selectable text and **Screen Recording** for image text. Choose **Allow Accessibility** and **Allow Screen Recording**, then complete the macOS prompts. Updates keep your setup choices. If neither permission is available, choose **Set Up Reading Permissions…** in the eye menu. You can return to the setup from **eye menu → Settings… → Review Permissions…**. Use **Capture Screen Area** to drag around text, or **Capture Window** to read a whole window. **Capture Window** centers the result on the source display and filters lines by the study language. For a long capture, use **Captured passage** in the card to find your line, then choose a word. Recognition uses Apple Vision or Live Text. The app can also use an existing Homebrew Tesseract installation with matching traineddata files.

The app requires macOS 15 or later and includes Apple Silicon and Intel binaries. This beta is ad-hoc signed. If macOS asks you to review the build when you open it, follow [Apple’s instructions for a trusted app](https://support.apple.com/en-us/102445).

## Keyboard shortcuts

The eye menu displays the shortcuts next to each action. They work while another app has focus. The shortcuts under **Card Actions** apply to the open Companion card.

Click the floating card once to grade with a single key. **U** resets to Unknown, **1–4** set a learning level, **K** marks Known, and **I** ignores the word. You can also use the modifier-based shortcuts below.

| Action | Shortcut |
| --- | --- |
| Look up selection or pointer | ⌃⌥L |
| Toggle automatic hover | ⌃⇧H |
| Capture screen area | ⌃⇧A |
| Capture window | ⌃⇧W |
| Connect or show Sluka reader | ⌃⇧S |
| Translate selection | ⌃⇧T |
| Previous or next word | ⌃⇧B or ⌃⇧N |
| Copy captured text | ⌃⇧C |
| Pin or unpin card | ⌃⇧P |
| Close card | ⌃⇧D |
| Reset to Unknown | ⌃⇧0 |
| Set level 1–4 | ⌃⇧1 through ⌃⇧4 |
| Mark Known | ⌃⇧K |
| Ignore word | ⌃⇧X |

## Sluka

The first lookup opens the local Sluka reader in Chrome. Leave that tab open in the Chrome profile where Sluka is installed. Use **Connect Sluka** in the card or eye menu if the connection needs attention. Choose the same study language in Sluka and enable Hover preview. If the card asks you to activate Sluka, select **Open Reader in Chrome** and use **Activate Sluka here** in Sluka’s toolbar menu.

When Sluka skips a word in a passage, the reader tries just that word and can reload once with the word already on the page. The Mac card keeps the original passage and highlights your selection.

The reader closes the dictionary cards it opens as you move between words. If the definition for a Known word is still missing, choose **Open Reader in Chrome** and click the word in the reader.

Use **Translate selection** on a text selection or capture to show a passage translation beneath the original. The translation uses your Sluka settings. Sluka may send the selected passage to Google Translate. Choosing a word still shows its Sluka dictionary definition and grade. For captures with a passage picker, the button translates the displayed passage. If Sluka cannot translate it from the card, use **Open Sluka Reader** to select the text there.

**Unknown**, **1–4**, **Known**, and **Ignore** use Sluka’s grade controls. **Unknown** resets the word to Sluka’s New status. Sluka handles storage and any sync you have enabled. The card can show a verified definition for a grammar entry even when the entry has no writable grade. If Sluka splits a phrase differently, use the word choices in the card. [Sluka’s grading guide](https://sluka.app/guide#keyboard)

The **Study Language** menu includes all of Sluka’s built-in languages. Choose the same study language in Companion and Sluka. When Sluka identifies the word under the pointer, the card uses its word boundaries. If **Other matches** appears, choose a different word boundary to see its Sluka definition. The highlight shows which characters you are looking up. The card gets its definitions from Sluka. OCR Companion loads the bundled Chinese segmentation data when you first look up Chinese text. A language marked **Image word picker** uses region OCR and lets you choose a word. A language marked **Selectable text only** uses Accessibility. The reader tab comes from the Mac app and uses your existing Sluka extension.

## Window capture check

On macOS Tahoe 26.3.1, ScreenCaptureKit and Apple Vision previously read three lines exactly from a Chinese sample open in Preview. In a separate live test of the 3.7 reader bridge, Sluka returned its definition and Unknown grade for 戈 in an English sentence while the reader tab was in the background.

## Source

The source folder contains the LongYan selection and popup code, OCR Companion’s screen OCR and local Sluka bridge, and the desktop entry point for this edition. The original dictionary data helps segment Chinese text. Sluka provides the definitions displayed in the card. It builds with the Xcode Command Line Tools.

- Run zsh build.sh from the source folder to build the universal app.
- Run zsh Tests/run.sh to test the Sluka bridge and native command policy.
- See Licenses for the MIT notices and CC-CEDICT terms. The LongYan code is based on upstream commit 7ff9a2fb0740648258347526a7ce9b0945763e53.
