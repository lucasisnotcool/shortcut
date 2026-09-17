# Demo material

Made-up course content for testing Shortcut and for the screenshots in
[FEATURES.md](../FEATURES.md). Nothing here comes from a real course.

- `Demo Course/`: two short notes files to add as a reference folder.
- `quizzes/`: one quiz page per question type.
- `quiz-viewer.swift`: shows a page in a plain window with a neutral
  backdrop (no browser toolbar, tabs or bookmarks):
  `quiz-viewer <page.html> [width height [left top]]`.

| Page | Type | Expected answer |
|---|---|---|
| `single.html` | single | B |
| `multiple.html` | multiple | 1 3 |
| `truefalse.html` | true_false | F |
| `dropdown.html` | dropdown | 3 |
| `ranking.html` | ranking | 2 4 1 5 3 |
| `matching.html` | matching | C B D A (window at least 540 pt tall, or the last row is cut off and the answer is "none") |
| `numeric.html` | numeric | 3200 |
| `fillblank.html` | fill_blank | glucose, oxygen |
| `noquestion.html` | none | no question on screen |
| `twoquestions.html` | single | C (question 10; question 9 is already finished) |

All ten were checked live on 2026-09-17 with `opus[1m]` and gave these answers.
Load `Demo Course` as the only reference folder when testing, and check that
the quiz window is in front before every window check (see AGENTS.md).
