import type { ProjectStats } from "../types";

export const PRICING = {
  opus: { input: 15, output: 75 },
  sonnet: { input: 3, output: 15 },
  haiku: { input: 0.8, output: 4 },
} as const;

export function calculateCost(stats: ProjectStats): number {
  const totalMessages = stats.opus_messages + stats.sonnet_messages + stats.haiku_messages;
  if (totalMessages === 0) return 0;

  const opusRatio = stats.opus_messages / totalMessages;
  const sonnetRatio = stats.sonnet_messages / totalMessages;
  const haikuRatio = stats.haiku_messages / totalMessages;

  const weightedInputPrice =
    opusRatio * PRICING.opus.input +
    sonnetRatio * PRICING.sonnet.input +
    haikuRatio * PRICING.haiku.input;

  const weightedOutputPrice =
    opusRatio * PRICING.opus.output +
    sonnetRatio * PRICING.sonnet.output +
    haikuRatio * PRICING.haiku.output;

  const inputCost = (stats.total_input_tokens / 1_000_000) * weightedInputPrice;
  const outputCost = (stats.total_output_tokens / 1_000_000) * weightedOutputPrice;

  return inputCost + outputCost;
}
