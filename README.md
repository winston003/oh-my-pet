# oh-my-pet

> A macOS-first AI desktop companion you can create, voice, and keep close on your screen.

![status](https://img.shields.io/badge/status-pre--alpha-orange)
![platform](https://img.shields.io/badge/platform-macOS--first-blue)
![license](https://img.shields.io/badge/license-undecided-lightgrey)

Languages: English | [简体中文](README.zh-CN.md)

## Overview

`oh-my-pet` is an early public project exploring a user-owned AI desktop companion for macOS.

The goal is not to build a generic chatbot with a cute skin. The goal is to create a quiet, personal desktop pet with its own visual identity, voice, memories, and small shared rituals with the user.

The product should feel like:

> I created this little companion. It lives on my desktop, quietly keeps me company, and remembers small things we finished together.

## Current Status

`oh-my-pet` is in **pre-alpha product design**. There is no runnable app in this repository yet.

The repository currently contains public product direction and collaboration guidance. Early implementation work will likely start with small macOS experiments, profile format drafts, and lightweight UI prototypes.

Development is expected to move in small, frequent commits so the project is easy to follow and review.

## Core Ideas

- **macOS-first**: start with a polished native desktop experience.
- **Emotion-first**: quiet presence matters more than constant conversation.
- **User-created identity**: users can create their pet with AI-generated images and voice.
- **Local pet profile**: pet assets, personality, voice metadata, memories, and settings should live in a local profile.
- **BYOK-friendly**: users should be able to bring their own AI provider keys.
- **Permission-transparent**: the pet may feel aware, but it must be honest about what it can access.

## Planned MVP

The first product direction is organized around five systems.

| Area | Direction |
| --- | --- |
| AI Pet Studio | Create a pet with text-to-image, image-to-image, reference images, state images, voice generation, and consent-based voice cloning. |
| Desktop Pet Runtime | Show the pet as a transparent floating macOS layer with drag, resize, hide/show, always-on-top behavior, and quiet state changes. |
| Pet House | Keep the pet's identity, visual states, voice profile, small memories, stickers, room objects, generation history, and import/export data. |
| Focus And Task Companion | Let the pet quietly accompany focus sessions and task completion, then record small shared memories. |
| Scene-Based Selection Assistant | Help with selected text only after user action, with clear context about what may be sent to the configured provider. |

The first runtime can use static transparent state images plus light animation. The profile format should leave room for richer runtimes later, such as sprites, Live2D, Spine, skeletal animation, or video sprites.

## Privacy And Permissions

Privacy is part of the product design, not a later patch.

Expected boundaries:

- No secret screen watching.
- No secret microphone listening.
- No automatic file, browser, chat, or selected-text reading.
- No continuous screen observation in the MVP.
- Selected text should only be read after explicit user action.
- AI actions should show the provider, model, and data type involved.
- Provider keys should be stored in macOS Keychain.
- Generated pet assets, voice metadata, memories, and settings should be stored locally.

App/window awareness may require macOS Accessibility permission. The intended use is limited to context such as current app identity, window title, and basic window position. It should not mean continuous screen reading.

## Technical Direction

The current design favors a native macOS prototype:

- SwiftUI + AppKit for the host app.
- AppKit for transparent floating windows, menu bar behavior, window levels, drag/resize, and desktop integration.
- macOS Keychain for provider keys.
- Accessibility APIs for optional app/window awareness.
- A local pet profile package for visual assets, voice metadata, behavior mapping, house data, and memory records.
- Provider adapters for AI image, voice, and text calls.

This is still a design direction, not an implemented stack.

## Roadmap

Early public milestones:

- Public product direction and privacy boundaries.
- macOS transparent floating pet prototype.
- Local pet profile format.
- Pet Studio proof of concept.
- Pet House prototype.
- Focus and task companion loop.
- Provider adapter experiments for image, voice, and text generation.

The roadmap will stay modest until the first runnable prototype exists.

## Repository Contents

```txt
oh-my-pet/
  AGENTS.md
  README.md
  README.zh-CN.md
```

## Contributing

This is an open collaboration space for people who care about careful desktop companionship, local control, macOS craft, privacy, and honest AI.

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

- Therapy or medical claims.
- Full autonomous computer control.
- Continuous screen recording.
- Unapproved file, browser, chat, or selected-text reading.
- Unapproved voice cloning.
- Hunger decay, health penalties, punishment, or guilt loops.
- NFT or chain-based assets.
- Unlicensed IP character packs.
- A forced account system.

## License

The code license is not decided yet.

Assets such as pet images, generated voices, actions, and profile packs may need separate license and consent rules. Do not assume this repository grants reuse rights until a license is explicitly added.

## One Sentence

`oh-my-pet` is an early attempt to make a user-owned AI desktop companion: personal in appearance, personal in voice, quiet by default, and honest about what it can access.
