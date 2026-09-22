# Accessibility Action Plan

This plan translates the accessibility review into implementation work. It is ordered by user impact: first make the map understandable without sight, then make the visual encoding usable for colorblind and low-vision users, then tighten keyboard and assistive-technology behavior across the custom controls.

## Goals

- The site must be usable with screen readers and keyboard-only navigation.
- The map must have a non-visual equivalent for the selected dataset, variable, and year.
- Color must not be the only way to understand class, status, dataset, or coverage information.
- Interactive controls must expose correct names, roles, values, state, focus order, and keyboard behavior.

## Phase 1: Provide a Screen-Reader Equivalent for the Map

### 1. Add an accessible current-map summary

Create a live textual summary near the map, visually hidden or placed in an expandable panel, that updates when dataset, variable, year, projection, polarity, or class breaks change.

The summary should include:

- selected dataset title
- selected variable title and key
- selected year
- polarity/legend interpretation
- number of countries with data
- number of countries without data
- quantile class count
- class ranges when available

Recommended implementation:

- Add a region such as `role="region"` with `aria-labelledby`.
- Use `aria-live="polite"` only for concise updates, not the entire table.
- Reuse `/api/class-breaks` for class ranges and country counts.

### 2. Add an accessible data table for the selected map state

Provide a table view for the currently selected dataset, variable, and year.

Minimum columns:

- country name
- ISO3
- raw value
- quantile class
- no-data status

Recommended controls:

- Toggle button: `Show data table` / `Hide data table`
- Download link for the current table, if feasible
- Sortable columns only if implemented with proper button labels and `aria-sort`

Backend work may be needed because the current WMS image cannot be queried by assistive software.

### 3. Make the map container explicitly non-textual

Once the summary/table exists, give the rendered map an accessible description that points users to the equivalent data.

Recommended implementation:

- Label the map area as an interactive visual map.
- Use `aria-describedby` to reference the map summary.
- Avoid making the canvas/tile internals part of the accessibility tree unless they expose useful controls.

## Phase 2: Improve Colorblind and Low-Vision Support

### 4. Replace or augment the current quantile color ramps

The current adjacent legend colors have low contrast, especially the neutral green ramp. Update palettes so classes differ by lightness as well as hue.

Requirements:

- Adjacent classes should remain distinguishable under common color-vision deficiencies.
- The no-data color must not be confused with a low or high data class.
- Positive and negative polarity legends must remain semantically clear.

Validation:

- Check simulated protanopia, deuteranopia, tritanopia, and grayscale.
- Check adjacent swatch contrast and visual separation.
- Verify real WMS output, not only CSS legend colors.

### 5. Add non-color cues to map classes

Color alone should not carry the quantile class.

Options to evaluate:

- stronger class boundaries
- optional outline or hatch overlays
- legend labels for class numbers
- inspectable country/hex details in an accessible table

Prefer solutions that do not make the WMS layer visually noisy at global zoom.

### 6. Make coverage strips accessible

Coverage strips currently rely on tiny visual bars and `title` attributes.

Actions:

- Add text equivalents to each variable row, such as `Data 1900-2025, up to 165 countries`.
- Expose that text through the radio label or `aria-describedby`.
- Keep the existing SVG `aria-hidden` if a text equivalent is present.
- Do not rely on browser `title` for essential information.

## Phase 3: Fix Keyboard Focus and Control Semantics

### 7. Restore visible focus indicators

Fix controls where keyboard focus is hidden or weak.

Targets:

- timeline range input
- OpenLayers zoom buttons
- playback/speed buttons
- map projection radio controls
- legend swatches
- mobile picker options

Requirements:

- Focus indicator must be visible at all times in keyboard navigation.
- Indicator must meet WCAG focus appearance expectations where practical.
- Do not remove outlines without providing an equally visible replacement.

### 8. Improve the timeline range input

The transparent native range input is keyboard-operable but visually disconnected from focus.

Actions:

- Show focus on the custom timeline marker or track when the range input receives focus.
- Ensure the range exposes current year, min year, max year, and step correctly.
- Consider `aria-valuetext`, for example `2025, data available`, when year availability matters.
- Ensure unavailable years are explained without relying only on visual preload segments.

### 9. Remove non-interactive focus stops

Review and remove `tabindex="0"` from non-interactive containers unless they expose meaningful keyboard behavior.

Known target:

- `#datasetPanel`

If the panel needs a programmatic focus target, give it an explicit role, label, and reason to be focusable.

## Phase 4: Correct Custom Widget Patterns

### 10. Rework variable info from tooltip to accessible popover/dialog

The persistent variable information card behaves more like a popover than a tooltip.

Actions:

- Use a dialog/popover pattern for click-triggered variable info.
- Move focus into the popover/dialog or keep focus on the trigger with a correct relationship, depending on chosen pattern.
- Add a close button for persistent content.
- Restore focus to the trigger on close.
- Use `aria-expanded`, `aria-controls`, and either `aria-labelledby` or `aria-describedby` where appropriate.
- Keep hover-only previews optional and non-essential.

### 11. Associate legend details with focused swatches

Legend swatches are keyboard-focusable, but their dynamic range/count details are not programmatically tied to the focused swatch.

Actions:

- Give each swatch a complete accessible name or description once class breaks are known.
- Include class number, range, and country count.
- Use `aria-describedby` only if the referenced tooltip content is stable and present.
- Consider replacing focusable `role="img"` spans with buttons if interaction is expected.

### 12. Fix the mobile variable picker semantics

The mobile picker currently uses `role="listbox"` with button children marked as `role="option"`, but it does not implement full listbox keyboard behavior.

Choose one path:

- Simple path: make it a grouped list of buttons and remove `role="listbox"` / `role="option"`.
- Full ARIA path: implement proper listbox behavior with arrow keys, Home/End, typeahead, selected option management, and `aria-activedescendant`.

Recommended path: use the simple grouped-button pattern unless there is a strong reason to mimic a native select.

### 13. Improve mobile dialog naming and state

Actions:

- Give the dialog heading an ID.
- Add `aria-labelledby` to the `<dialog>`.
- Toggle `aria-expanded` on the opener.
- Confirm Escape closes the dialog and returns focus to the opener.
- Verify focus is trapped while the modal dialog is open.

## Phase 5: Announcements and Loading States

### 14. Announce meaningful map state changes

Add polite announcements for major changes:

- variable selected
- dataset changed
- year changed
- map loading started/completed when loading takes noticeable time
- no data for selected year

Avoid announcing high-frequency events during autoplay or pointer scrubbing.

### 15. Review loading indicators

The loading spinner is hidden from assistive technology. That is acceptable for short loads, but longer map loads should have an accessible status.

Actions:

- Add a concise `role="status"` message for delayed loads.
- Clear or update the message when the map finishes loading.
- Respect `prefers-reduced-motion` for all spinners and animated preload markers.

## Phase 6: Testing and Acceptance Criteria

### 16. Add manual keyboard test cases

Document and run keyboard-only workflows:

- search variables
- apply and clear topic filters
- apply and clear dataset filters
- select a variable
- open and close variable information
- change year with keyboard
- play/pause timeline
- adjust playback speed
- switch projection
- inspect legend class details
- open, search, select, and close mobile picker

Acceptance:

- Every interactive element is reachable.
- Focus order follows the visible layout.
- Focus is always visible.
- Escape closes transient overlays.
- Focus returns predictably after dialogs/popovers close.

### 17. Add screen-reader smoke tests

Manual tests should cover at least NVDA/Firefox and VoiceOver/Safari if available.

Core checks:

- page title and landmarks are understandable
- current map state is announced
- variable rows have useful names and selected state
- coverage information is available without hover
- legend classes expose range/count information
- mobile dialog has a name and focus behavior is correct

### 18. Add automated accessibility checks

Add a lightweight automated audit to catch regressions.

Recommended tooling:

- Playwright for rendering desktop and mobile states
- axe-core for accessibility rules

Suggested checks:

- initial desktop view
- filtered variable list
- variable info popover/dialog open
- legend focused state
- mobile picker open

Automated checks will not validate map equivalence or colorblind usability by themselves; keep manual review in the release checklist.

### 19. Add color and contrast checks

Add a small script or documented procedure to validate:

- text/background contrast for UI tokens
- legend adjacent-class separation
- no-data color separation
- grayscale readability
- color-vision-deficiency simulations

Run this whenever palettes or WMS styles change.

## Suggested Implementation Order

1. Add accessible map summary and current-state data table.
2. Fix visible keyboard focus for timeline, zoom, and custom controls.
3. Expose coverage strip text through labels/descriptions.
4. Rework variable info and legend details into accessible patterns.
5. Revise map and legend color ramps, then validate with colorblind simulations.
6. Fix mobile picker semantics and dialog state.
7. Add automated accessibility smoke tests and manual release checklist.

## Definition of Done

- A screen-reader user can determine what dataset, variable, year, legend meaning, class ranges, and country values are currently shown.
- A keyboard-only user can complete the main workflows without losing focus or relying on a pointer.
- A colorblind user can distinguish map classes or access equivalent class/value information without depending on hue alone.
- Essential information is not conveyed only by `title`, hover, color, animation, or canvas/WMS imagery.
- Accessibility checks are part of the normal verification path before release.
