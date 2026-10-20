/**
 * `:name:` shortcodes a template may use; the app's emoji picker shows the same table
 * (`emoji` in `suica templates show --json`). Names follow GitHub's and Slack's.
 */
export const EMOJI: Readonly<Record<string, string>> = {
  wave: "👋",
  pray: "🙏",
  tada: "🎉",
  rocket: "🚀",
  fire: "🔥",
  eyes: "👀",
  smile: "😄",
  grin: "😁",
  joy: "😂",
  wink: "😉",
  blush: "😊",
  sweat_smile: "😅",
  thinking: "🤔",
  sunglasses: "😎",
  hugs: "🤗",
  heart: "❤️",
  sparkles: "✨",
  star: "⭐",
  "+1": "👍",
  thumbsup: "👍",
  clap: "👏",
  raised_hands: "🙌",
  muscle: "💪",
  ok_hand: "👌",
  white_check_mark: "✅",
  heavy_check_mark: "✔️",
  x: "❌",
  warning: "⚠️",
  bug: "🐛",
  wrench: "🔧",
  hammer: "🔨",
  memo: "📝",
  mag: "🔍",
  bulb: "💡",
  zap: "⚡",
  hourglass: "⏳",
  alarm_clock: "⏰",
  coffee: "☕",
  watermelon: "🍉",
  penguin: "🐧",
  rotating_light: "🚨",
  construction: "🚧",
  package: "📦",
  bell: "🔔",
  speech_balloon: "💬",
  point_right: "👉",
  technologist: "🧑‍💻",
  partying_face: "🥳",
  star_struck: "🤩",
  slightly_smiling_face: "🙂",
};

const SHORTCODE_PATTERN = /:([a-z0-9_+-]+):/g;

/** Replaces each known `:name:`; an unknown one (or a time such as `10:30:`) stays as written. */
export function expandShortcodes(text: string): string {
  return text.replace(SHORTCODE_PATTERN, (whole, name: string) =>
    Object.hasOwn(EMOJI, name) ? (EMOJI[name] ?? whole) : whole,
  );
}
