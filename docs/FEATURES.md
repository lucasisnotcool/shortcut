# What Shortcut does: a visual tour

Shortcut is a small Mac app for teaching staff. While you present a quiz, it
reads the question on your screen, works out the answer from your course
materials, and shows it to you alone in the menu bar. You can also ask it
anything about the course from a pop-up chat box.

Every screenshot here comes from the real app running on a Mac. The course,
questions and notes are **made-up demo material** (in
[`docs/demo`](demo/)). Each answer shown was produced live by Claude and
matched the expected answer.

There are three ways to use it:

1. [**Menu bar**](#1-the-menu-bar): press both Option keys and the answer
   appears as a small badge at the top of the screen.
2. [**Quick chat**](#2-quick-chat): double-tap Option to ask a question
   without leaving your slides.
3. [**Main window**](#3-the-main-window): choose your course folders and
   read the full conversation.

---

## 1. The menu bar

Put the quiz on screen and press **left Option + right Option** together.
Shortcut captures the window in front, checks the question against your
course files, and shows the answer as a badge in the menu bar. Only you see
it; the app or web page underneath receives no key presses.

Click the badge for the reasoning, with a ✓ or ✗ for every option:

<img src="images/menu-bar.png" alt="Menu-bar menu showing the dropdown answer, its reasoning and the menu items" width="420">

The badge changes with the question type:

| Question | Badge | What it means |
|---|---|---|
| Single answer | <img src="images/badge-single.png" alt="B" height="30"> | Choose B |
| Multiple response | <img src="images/badge-multiple.png" alt="1 3" height="30"> | Tick 1 and 3 |
| True / false | <img src="images/badge-truefalse.png" alt="F" height="30"> | False |
| Dropdown (list open) | <img src="images/badge-dropdown.png" alt="3" height="30"> | The 3rd item from the top of the list |
| Ranking | <img src="images/badge-ranking.png" alt="2 4 1 5 3" height="30"> | The options in order, first to last |
| Matching | <img src="images/badge-matching.png" alt="C B D A" height="30"> | The choice for item 1, 2, 3, 4 |
| Number | <img src="images/badge-numeric.png" alt="3200" height="30"> | Type 3200 |
| Free-text blanks | <img src="images/badge-fillblank.png" alt="pencil" height="30"> | The words are in the menu and the chat |
| No answer | <img src="images/badge-noquestion.png" alt="!" height="30"> | No complete question on screen; the menu says why |

While Claude is working, the circle spins. A check takes a few seconds.

### Each question type in action

In each picture, the quiz window is on the left. On the right is the same
check as it appears in the chat box: the captured screenshot, the answer and
the explanation.

**Single answer.** The answer is taken from the course notes and cites the
file it came from.

![Single-answer question answered B](images/check-single.png)

**Multiple response.** Every option is judged on its own, including
negatives such as "NOT found in animal cells".

![Multiple-response question answered 1 and 3](images/check-multiple.png)

**True / false**

![True/false question answered False](images/check-truefalse.png)

**Dropdown.** With the list open, the badge gives the position in the list,
counted from the top.

![Dropdown question answered option 3](images/check-dropdown.png)

**Ranking.** The badge lists the option numbers in the right order. The
order currently on screen is ignored.

![Ranking question answered 2 4 1 5 3](images/check-ranking.png)

**Matching.** One choice per item, in item order.

![Matching question answered C B D A](images/check-matching.png)

**Number**

![Numeric question answered 3200](images/check-numeric.png)

**Free-text blanks.** The text for each blank is in the chat and the menu.

![Fill-in-the-blank question answered glucose and oxygen](images/check-fillblank.png)

**Several questions on one page.** Shortcut answers the first question that
is fully visible and not yet finished. Here it skips question 9 (already
marked correct) and answers question 10.

![Page with a finished question 9 and question 10, answered C](images/check-twoquestions.png)

**No answer instead of a guess.** Shortcut refuses rather than guesses when
there is no question on screen, or when part of the question is cut off.

![Lecture slide with no question: no answer](images/check-noquestion.png)

![Matching question cut off at the bottom of the window: no answer, asks to scroll](images/check-cutoff.png)

---

## 2. Quick chat

**Double-tap Option** anywhere to open the chat box over whatever you are
presenting. Type a question and press Return. Escape or a click elsewhere
closes it. You can paste images with ⌘V, and drag the box to wherever you
want it.

The box shows only the latest question and answer. Answers come from your
course files first and say which file they used.

![Quick chat over a lecture slide, summarising the Week 2 notes](images/quick-chat.png)

---

## 3. The main window

Open it from the menu (**Shortcut Settings…**). On the left:

- **Permission checks.** The pills turn to ✓ once macOS has granted
  Accessibility and Screen Recording.
- **Reference folders.** Every file in the folders you add is loaded, and
  each file shows whether it is ready. **Verify** asks Claude to list what
  it can see.
- **Gesture reminder.** The two key gestures, at the bottom.

On the right is the one shared conversation: every quick-chat question and
window check, with full explanations. **Reset Conversation** starts a new
one and keeps your folders. **Prompts…** shows exactly what is sent to
the model and lets you adjust the instructions. **Models…** holds the
ranked model list: Claude Code, API keys for Anthropic, OpenAI, Gemini,
OpenRouter and others, or a local Ollama or LM Studio model. The first
available model answers and the next one takes over if it fails; each reply
names the model that wrote it.

![Main window with the Demo Course folder loaded and the shared conversation](images/main-window.png)

---

## Good to know

- Shortcut is personal-use software: you build it on your own Mac and it
  uses your own claude.ai plan or API keys. See the [README](../README.md) to set it up,
  or ask a coding agent to follow [AGENTS.md](../AGENTS.md).
- A window check sends a screenshot of **whatever window is in front**.
  Make sure that is the quiz, not your email or notes.
- Your course files, screenshots and chat are sent to the model provider
  that answers (Anthropic's Claude by default; local models stay on your
  Mac). Only add material you are comfortable sharing that way.
- The demo material and the quiz viewer used for these screenshots are in
  [`docs/demo`](demo/). You can use them to test your own setup.
