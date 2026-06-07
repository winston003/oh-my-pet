# oh-my-pet

> A macOS-first AI desktop companion that users can create, voice, and keep on their screen.

![status](https://img.shields.io/badge/status-pre--alpha-orange)
![platform](https://img.shields.io/badge/platform-macOS--first-blue)
![license](https://img.shields.io/badge/license-TBD-lightgrey)

## Current Status

`oh-my-pet` is in **pre-alpha product design**. There is no runnable app in this repository yet.

The current work is about defining the product honestly before building it:

- What kind of desktop companion should it be?
- What should it never do without explicit permission?
- How should AI-generated images, voices, memories, and desktop context fit together?
- What should stay local, user-owned, and inspectable?

Public implementation notes will be added as the prototype becomes real. Early product research and planning notes are intentionally kept out of the public repository until they are ready to be maintained as stable public docs.

## Development Rhythm

This repository is expected to move in small, frequent commits.

Early progress may look modest: a clearer README, a tiny macOS window experiment, a safer permission note, a pet profile sketch, or a small UI prototype. That is intentional. Frequent commits make the project easier to follow, easier to review, and more honest about what is changing.

If you are watching the project, expect visible incremental work rather than long silence followed by a large drop.

## What This Is

`oh-my-pet` is intended to be a personal desktop companion, not just a chat window with a cute skin.

The first product direction is:

- **macOS-first**: start with a polished desktop experience on macOS.
- **Emotion-first**: the pet should feel personal, calm, and present.
- **AI-created identity**: users can create a pet with text-to-image, image-to-image, reference images, voice generation, and voice cloning.
- **Local pet profile**: the pet's images, voice metadata, personality, memories, and generation history are stored as a local profile.
- **BYOK-friendly**: users bring their own AI provider keys; keys should be stored in macOS Keychain.
- **Desktop-aware, not secretly watchful**: app/window awareness is useful, but screen reading is not a default behavior.

The product should feel like:

> "I created this little companion. It lives on my desktop, quietly keeps me company, and remembers small things we finished together."

## What This Is Not

`oh-my-pet` is not trying to be:

- A therapy product.
- A general-purpose autonomous agent.
- A tool that secretly watches the screen.
- A tool that secretly listens through the microphone.
- A tool that reads files, browser content, chat logs, or selected text without user action.
- A replacement for real relationships, medical care, or professional support.

The pet may feel aware, but it should never be deceptive about what it can access.

## MVP Shape

The MVP is designed around five pieces.

### 1. AI Pet Studio

Users create their own pet instead of choosing from a fixed list.

Planned creation modes:

- Text-to-image.
- Image-to-image.
- Reference image guided generation.
- State image generation for `idle`, `focus`, `happy`, `tired`, and `celebrate`.
- Voice style generation.
- Voice cloning with explicit user consent.

The first runtime can use static transparent state images plus light animation. The profile format should still leave room for richer runtimes later, such as sprites, Live2D, Spine, skeletal animation, or video sprites.

### 2. Desktop Pet Runtime

The pet lives as a transparent floating macOS layer.

Expected basics:

- Drag.
- Resize.
- Hide/show.
- Always-on-top behavior.
- Quiet idle state.
- Focus, tired, happy, and celebration states.
- A small quick menu for focus, tasks, Pet House, Pet Studio, and hiding.

The default tone is quiet: act more, talk less.

### 3. Pet House

The Pet House is not a heavy simulation game. It is a small memory space.

It should contain:

- Pet name and personality.
- Visual state gallery.
- Voice profile.
- Today companion record.
- Completed focus/task memories.
- Stickers and small room objects.
- Generation history.
- Pet profile import/export.

The goal is emotional ownership, not chores or punishment.

### 4. Focus And Task Companion

The main loop is simple:

1. Start a focus session or add a task.
2. The pet enters a focus state.
3. The app stays quiet while the user works.
4. Completion triggers a celebration.
5. The Pet House records a small shared memory.

There should be no hunger decay, forced check-in, health penalty, or guilt loop.

### 5. Scene-Based Selection Assistant

The pet can help with selected text, but only after the user triggers it.

Examples:

- In developer tools: explain code, break down a bug, summarize an error log, write a commit message.
- In documents or browsers: summarize, rewrite, translate, extract tasks.

The assistant should show clearly what kind of content will be sent to the configured provider.

## AI And Provider Model

The MVP direction is **BYOK-first**.

That means:

- Users configure their own AI provider keys.
- Keys should be stored in macOS Keychain.
- Provider, model, and data type should be visible during AI actions.
- Generated images, voice metadata, memories, and pet profile data should be stored locally.
- Provider settings should be removable.

The project should support provider adapters rather than hard-coding one model.

## Voice Cloning

Voice is part of the pet's identity.

Voice cloning is powerful and sensitive, so the product should treat it carefully:

- The user must explicitly confirm they own or have permission to use a voice sample.
- Voice samples and generated voice metadata should be deletable.
- The pet should not speak constantly.
- Subtitles and mute controls should be available.

Voice is for recognition and emotional connection, not noise.

## Privacy And Permissions

The intended permission model is layered.

### Base Mode

No high desktop permission should be required for:

- Creating a pet.
- Generating image or voice assets.
- Showing the pet.
- Opening the Pet House.
- Running focus/task flows.

### App And Window Awareness

App/window awareness may require macOS Accessibility permission.

The intended use is limited:

- Current app identity.
- Window title.
- Basic window position.
- Context-specific pet state and assistant actions.

This should not mean continuous screen reading.

### Selected Text

Selected text should only be read after user action.

### Screen Observation

Continuous screen observation and OCR are not part of the MVP.

If explored later, they must be separately enabled, explainable, pausable, and auditable.

## Repository Contents

This repository currently contains project direction material, not an application build.

```txt
oh-my-pet/
  AGENTS.md
  README.md
```

## Likely Technical Direction

The current design favors a native macOS prototype:

- SwiftUI + AppKit for the host app.
- Transparent floating windows and menu bar behavior in the macOS layer.
- Keychain for provider keys.
- Accessibility APIs for optional app/window awareness.
- A local pet profile package for visual, voice, behavior, house, and memory data.

This is still a design direction, not an implemented stack.

## How To Help

This is an open collaboration space for people who care about the idea. It is not a job board or a formal hiring process; it is for builders, designers, researchers, and curious users who want to shape a careful desktop companion together.

Useful contributions at this stage:

- macOS transparent floating window experiments.
- Pet profile format feedback.
- AI image consistency experiments.
- Voice generation and consent UX feedback.
- Privacy and permission review.
- Small UI prototypes for Pet Studio, Pet House, and desktop pet behavior.

Small contributions are welcome. A focused issue, a short experiment, a careful privacy review, or a small working prototype is more useful than a broad rewrite.

Please open an issue before large changes so the direction stays coherent.

## Non-Goals For Now

Short-term non-goals:

- Full autonomous computer control.
- Continuous screen recording.
- Unapproved file or browser reading.
- Unapproved voice cloning.
- NFT or chain-based assets.
- Unlicensed IP character packs.
- Complex 3D world editing.
- A forced account system.

## License

The code license is not decided yet.

Assets such as pet images, generated voices, actions, and profile packs may need separate license and consent rules. Do not assume this repository grants reuse rights until a license is explicitly added.

## One Sentence

`oh-my-pet` is an early attempt to make a user-owned AI desktop companion: personal in appearance, personal in voice, quiet by default, and honest about what it can access.
