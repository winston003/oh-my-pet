# AGENTS.md

This file is the operating guide for agents working in this repository. Treat it as project-level instruction. If it conflicts with a task request, ask for clarification before changing product direction.

## Project State

`oh-my-pet` is currently in pre-alpha product design. There is no runnable app yet.

The repository should present a clean, professional public starting point:

- Be honest about what exists and what does not exist.
- Do not imply there is a working product before one exists.
- Do not publish internal strategy or non-public roadmap details unless explicitly requested by the owner.
- Keep public docs focused on product purpose, privacy posture, technical direction, and contribution boundaries.

Primary public context:

- `README.md`: English public-facing project overview and primary GitHub entry point.
- `README.zh-CN.md`: Simplified Chinese public-facing project overview.
- `AGENTS.md`: project operating guide for future agents and contributors.

Keep the English and Chinese README files aligned. When product direction, privacy boundaries, roadmap, contribution language, or repository contents change in one README, update the other in the same commit unless the owner explicitly asks otherwise.

Private planning context may exist locally under `.private/`. It is not public source material and must not be committed unless the owner explicitly asks to publish a specific file.

## Product North Star

`oh-my-pet` is a macOS-first AI desktop companion that users can create, voice, and keep on their screen.

The product should feel like:

> I created this little companion. It lives on my desktop, quietly keeps me company, and remembers small things we finished together.

Priority order:

1. Emotional companionship.
2. AI-generated pet image and voice identity.
3. Local, user-owned pet profile.
4. macOS desktop presence.
5. App/window awareness with explicit permission.
6. Shared memories from focus and task completion.
7. User-triggered AI assistance.

Do not turn the product into a generic chatbot, a high-pressure productivity app, or an autonomous computer-control agent.

## Product Boundaries

The pet may feel aware, but it must never be deceptive about what it can access.

Default public promise:

- No secret screen watching.
- No secret microphone listening.
- No automatic file, browser, chat, or selected-text reading.
- No continuous screen observation in the MVP.
- No medical, therapy, or mental-health claims.
- No forced account system in the MVP direction.
- No hunger, health decay, punishment, guilt loops, or chores as the core emotional loop.

The desired emotional mode is quiet presence, not noisy interruption.

## MVP Scope

Keep the MVP scoped around five systems:

1. **AI Pet Studio**
   - Text-to-image pet creation.
   - Image-to-image and reference-image pet creation.
   - State images for `idle`, `focus`, `happy`, `tired`, and `celebrate`.
   - Voice style generation.
   - Voice cloning with explicit consent.

2. **Desktop Pet Runtime**
   - macOS transparent floating pet layer.
   - Drag, resize, hide/show, always-on-top behavior.
   - Static transparent state images plus light animation.
   - Runtime extension points for sprites, Live2D, Spine, skeletal animation, and video sprites.

3. **Pet House**
   - Pet identity, voice profile, state gallery, generation history.
   - Shared memories, stickers, small room objects.
   - Import/export of local pet profiles.

4. **Focus And Task Companion**
   - Simple focus and task flows.
   - Quiet during work.
   - Completion creates a small shared memory.

5. **Scene-Based Selection Assistant**
   - User-triggered selected-text actions.
   - Actions adapt to current app context.
   - Show what kind of content will be sent before sending.

## Technical Direction

Prefer a native macOS prototype until there is a strong reason to change.

Current preferred shape:

- SwiftUI + AppKit for the host application.
- AppKit for transparent floating windows, menu bar behavior, window levels, drag/resize, and desktop integration.
- macOS Keychain for provider keys.
- Accessibility APIs for optional app/window awareness.
- Local pet profile package for visual assets, voice metadata, behavior mapping, house data, and memory records.
- Provider adapter layer for AI image, voice, and text calls.

Do not hard-code the product to a single AI provider. BYOK and provider adapters are part of the core direction.

## Local-First And BYOK

The MVP direction is BYOK-first and local-profile-first.

Required posture:

- Store user provider keys in Keychain, not raw local files.
- Store generated pet assets locally.
- Store pet identity, generation metadata, memories, and settings in a local profile.
- Make provider, model, and data type visible in AI-related UI.
- Allow provider settings and voice profiles to be removed.

Do not add server dependencies, accounts, sync, or hosted AI assumptions unless the task explicitly asks for that design change.

## Voice And Consent

Voice is a major part of pet identity.

Voice cloning must be treated as sensitive:

- Require explicit confirmation that the user owns or has permission to use the sample.
- Make voice samples and generated voice profile metadata deletable.
- Provide mute and subtitle controls.
- Do not make the pet speak constantly.

Avoid building or documenting anything that encourages impersonation without consent.

## Privacy And Permission UX

Use layered permissions:

1. **Base Mode**
   - Pet creation, voice creation, desktop pet, Pet House, focus, and task flows should work without high desktop permissions.

2. **App/Window Awareness**
   - May request Accessibility.
   - Use it for current app, window title, and basic window position.
   - Do not present it as screen reading.

3. **Selected Text**
   - Read only after explicit user action.
   - Make the send action visible.

4. **Screen Observation/OCR**
   - Not part of the MVP.
   - If explored later, it must be separately enabled, explainable, pausable, and auditable.

## Public Documentation Rules

Public docs should be calm, direct, and trust-building.

Do:

- State project status plainly.
- State privacy and permission boundaries plainly.
- Link only to stable public docs that are intended to be maintained in the repository.
- Keep language understandable for early users and contributors.
- Mention uncertainty where the project has not yet decided.

Do not:

- Publish internal strategy or non-public roadmap details.
- Overpromise AI capability.
- Claim there is a runnable app before there is one.
- Use hype language that weakens trust.
- Add unauthorized IP, NFT, or speculative ecosystem promises.

## Engineering Rules

- Keep changes small and aligned with the current spec.
- Update docs when product behavior or privacy boundaries change.
- Prefer explicit data models over ad hoc asset folders.
- Keep generated assets, secrets, local profiles, and user data out of git.
- Do not commit `.DS_Store`, `.superpowers/`, local caches, provider keys, generated pet samples, or voice samples.
- When implementing, include a small sample pet profile that uses safe placeholder assets created for the repo.

## Commit Rhythm

The repository should feel alive without becoming noisy.

- Prefer small, frequent commits over large mixed commits.
- Each commit should have a clear purpose and a plain commit message.
- Commit docs, prototypes, scaffolding, and experiments as separate steps when practical.
- Keep unrelated changes out of the same commit.
- Push public progress regularly after a coherent checkpoint.
- Do not wait for a large release to show movement.

This project should give interested people confidence that it is being cared for steadily.

## Design Rules

- Build the actual app surface, not a marketing landing page.
- First-run experience should start with creating or importing a pet.
- The pet should feel owned by the user before asking for advanced permissions.
- Use quiet, precise interface copy for permission and AI-send moments.
- Prefer visible controls over hidden behavior.
- Treat Pet House as an emotional memory space, not a complex management sim.

## History And Repository Hygiene

This repository should stay clean as a public starting point.

- Keep commit history professional and easy to understand.
- Do not preserve scratch commits, temporary brainstorm artifacts, or abandoned public claims.
- If history is intentionally rewritten, use a clear initial commit message and push with care.
- Never commit private notes, secrets, provider keys, voice samples, or generated assets unless they are explicitly safe fixtures.

## Community Posture

Invite contributors as fellow travelers, not as an employment funnel.

- Welcome people who share the product values: emotional care, privacy, local control, macOS craft, and honest AI.
- Make contribution requests specific and approachable.
- Prefer respectful, practical feedback over hype.
- Encourage small experiments and clear issues.
- Avoid language that sounds like a pitch deck or growth campaign.

## When Unsure

Default to:

1. More privacy.
2. Less interruption.
3. More user ownership.
4. More local control.
5. Fewer public promises.

Then ask the owner before widening scope.
