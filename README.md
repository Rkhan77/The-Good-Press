# The Good Press

**Good news, shaped by you.**

The Good Press is a phone-first news reader that combines the familiar swipe interaction of a dating app with the visual character of a printed newspaper. Each card presents one constructive story with an AI-generated summary. Swipe right for more stories like it, or left for fewer.

## Live demo

[Try The Good Press on GitHub Pages](https://rkhan77.github.io/The-Good-Press/)

## Features

### Swipeable news feed

- Swipe right to see more stories from that topic.
- Swipe left to reduce similar stories in the feed.
- Use the large action buttons when tapping is easier than swiping.
- Use the left and right arrow keys on a keyboard.
- Undo the most recent choice at any time.

### Newspaper-inspired story cards

- Front-page typography and editorial layout.
- Clear article title, section, reading time and source.
- Short introduction followed by an AI-generated summary.
- Layered card deck with tactile swipe motion and visual feedback.

### Personal news agenda

- Every swipe updates a private preference profile.
- The **Your agenda** view ranks topics by interest.
- Preferences adapt continuously instead of forcing users through a setup questionnaire.
- Decisions, reading count and topic preferences persist between visits on the same device.

### Account and appearance settings

- A simple local reader profile with no sign-in required.
- One-tap light and dark colour modes.
- Appearance choice persists on the current device.
- The settings screen stays focused on account status and display preferences.

### Local AI through n8n

The feed is designed to accept stories produced by a local n8n workflow, allowing article selection and summarisation to stay inside a workflow you control. A production integration can wire this data source into the feed without exposing workflow controls to readers.

An article payload uses this structure:

```json
{
  "articles": [
    {
      "title": "A River Returns to the Heart of the City",
      "dek": "A once-buried waterway is flowing in daylight again.",
      "summary": "A concise AI-generated summary of the article.",
      "category": "Planet",
      "source": "Local Newsroom",
      "minutes": 2
    }
  ]
}
```

Required fields are `title`, `summary` and `category`. The app uses sensible defaults for optional fields.

### Responsive and accessible

- Designed around a one-handed mobile experience.
- Adapts to desktop and short-screen layouts.
- Accessible labels for every icon control.
- Keyboard navigation and escape-to-close panels.
- Respects the user's reduced-motion preference.
- Readable type sizes and strong contrast in both colour modes.

### Privacy-friendly by default

- Preference data is stored locally in the browser.
- No account or sign-in is required for the demo.
- No analytics or third-party tracking is included.

## Demo content

The repository includes six clearly labelled demo stories across Planet, Work, Community, Science, Ideas and Cities. The sample edition repeats so every interaction can be tested immediately.

## Technology

The demo is a dependency-free static web app built with semantic HTML, responsive CSS and vanilla JavaScript. It can be hosted on GitHub Pages or any static-file host.

## Run locally

Download the repository and open `index.html` in a browser, or serve the folder with any local static server.

## Project status

This is a working product prototype. It demonstrates the complete reading and preference-learning experience while leaving article sourcing, production recommendation logic and the n8n workflow under the owner's control.
