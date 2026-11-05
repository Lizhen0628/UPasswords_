# Design: Secure Index

The browser popup is a compact credential index: it should make the active site and the safest next fill action obvious without slowing down routine scanning.

## Palette

- Dominant: white `#FFFFFF` with cool neutral surfaces `#F4F6F8` and ink `#20262E`.
- Accent: cobalt `#2869B3`, reserved for primary actions and the current-site match.
- Semantic: success `#24724F`, danger `#A93443`; neither is used as decoration.
- Dark mode shifts the neutral ramp to graphite and raises accent luminance for contrast.

## Type

- Use the platform system sans stack for UI labels and controls; it keeps the popup native to the browser and avoids remote font loading.
- Use 18px section headings, 13–14px scanning text, and 16px generated-password text. Use the system monospace stack only for generated credentials.
- Keep labels sentence case and avoid decorative tracking.

## Form

- Radius scale: 0 / 4 / 6 / 8px; controls and compact rows use 4–6px.
- Spacing follows a 4px half-step on an 8px rhythm.
- Use flat surfaces and separators; reserve borders for controls and true grouping.
- The current-site match is the single accent surface in the list.

## Motion

- Feedback is brisk and quiet, with 100ms control transitions.
- Reduced-motion preferences disable panel entrance motion and transitions.

## Composition

- Focal point: the matching account choices anchored to the focused username field.
- Primary action: select one account; the trusted popup rechecks policy before filling it.
- Use a left-aligned header, compact search and filter controls, then a divider-led credential list. On login pages, a restrained shadow-root list sits beside the username field and appears only on focus.

## This design will not use

- Gradients, nested cards, or decorative shadows.
- Hidden row actions that require hover to discover.
- Promotional hero copy or external visual assets.
