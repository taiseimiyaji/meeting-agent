import type { Meeting, MeetingSummary, SummaryItem } from "./types";

import { meetingName, meetingStartStamp } from "./meetingName";

export function summaryMarkdown(meeting: Meeting, value: MeetingSummary) {
  const title = meetingName(meeting);
  const blocks = [`# ${title}`];
  if (meeting.title?.trim()) {
    blocks.push(new Date(meeting.startedAt).toLocaleString("ja-JP"));
  }
  blocks.push("## 要約", value.summary);
  if (value.topics.length) blocks.push("## トピック", value.topics.map(topic => `- ${topic}`).join("\n"));
  for (const discussion of value.discussions ?? []) blocks.push(`## ${discussion.title}`, discussion.summary);

  function appendItems(heading: string, items: SummaryItem[]) {
    if (!items.length) return;
    const lines = items.map(item => {
      const details = [item.assignee && `担当：${item.assignee}`, item.dueAt && `期限：${item.dueAt}`].filter(Boolean);
      return `- ${item.text.replace(/\n/g, "\n  ")}${details.length ? `（${details.join("、")}）` : ""}`;
    });
    blocks.push(`## ${heading}`, lines.join("\n"));
  }
  appendItems("決定事項", value.decisions);
  appendItems("未決事項", value.openQuestions);
  appendItems("アクションアイテム", value.actionItems);
  return blocks.join("\n\n") + "\n";
}

export function downloadSummary(meeting: Meeting, value: MeetingSummary) {
  const markdown = summaryMarkdown(meeting, value);
  const title = (meeting.title?.trim() || "ミーティング").replace(/[^\p{L}\p{N}\p{M} _-]/gu, "_").trim();
  const filename = `${meetingStartStamp(meeting).replace(" ", "_").replace(":", "-")}_${Array.from(title).slice(0, 50).join("") || "議事録"}.md`;
  const native = (window as Window & { webkit?: { messageHandlers?: {
    saveSummaryMarkdown?: { postMessage(payload: { filename: string; markdown: string }): void };
  } } }).webkit?.messageHandlers?.saveSummaryMarkdown;
  if (native) {
    native.postMessage({ filename, markdown });
    return;
  }
  const url = URL.createObjectURL(new Blob([markdown], { type: "text/markdown;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  document.body.append(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
