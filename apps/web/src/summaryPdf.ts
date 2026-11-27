import { jsPDF } from "jspdf";
import fontUrl from "@expo-google-fonts/zen-kaku-gothic-new/400Regular/ZenKakuGothicNew_400Regular.ttf?url";
import { api } from "./api";
import { resolveSummaryEvidence } from "./evidenceResolution";
import { meetingName, meetingStartStamp } from "./meetingName";
import { summaryFilename } from "./summaryMarkdown";
import type { Meeting, MeetingSummary, ScreenEvent, SummaryItem, TranscriptEvent } from "./types";

const timestamp = (ms: number) => [Math.floor(ms / 60000), Math.floor(ms / 1000) % 60]
  .map(part => String(part).padStart(2, "0")).join(":");

async function base64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(",")[1]);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

async function screenshot(screen: ScreenEvent) {
  const url = URL.createObjectURL(await api.screenImage(screen.imageUrl));
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    const scale = Math.min(1, 1800 / Math.max(img.naturalWidth, img.naturalHeight));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(img.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(img.naturalHeight * scale));
    const context = canvas.getContext("2d");
    if (!context) throw new Error("画像を変換できません。");
    context.fillStyle = "white";
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.drawImage(img, 0, 0, canvas.width, canvas.height);
    return canvas;
  } finally {
    URL.revokeObjectURL(url);
  }
}

export async function saveSummaryPdf(meeting: Meeting, summary: MeetingSummary, transcripts: TranscriptEvent[], screens: ScreenEvent[]) {
  const pdf = new jsPDF({ compress: true, putOnlyUsedFonts: true });
  const font = await fetch(fontUrl);
  if (!font.ok) throw new Error("日本語フォントを読み込めません。");
  pdf.addFileToVFS("minutes.ttf", await base64(await font.blob()));
  pdf.addFont("minutes.ttf", "Minutes", "normal");
  pdf.setFont("Minutes");
  pdf.setProperties({ title: meetingName(meeting) });
  const width = 174;
  let y = 23;
  function room(height: number) {
    if (y + height > 277) { pdf.addPage(); y = 23; }
  }
  function paragraph(text: string, size = 11, color = "#172e29") {
    pdf.setFontSize(size);
    pdf.setTextColor(color);
    const leading = size * 0.51;
    for (const line of pdf.splitTextToSize(text, width)) {
      room(leading);
      pdf.text(line, 18, y);
      y += leading;
    }
    y += 2;
  }
  function heading(text: string) {
    room(21);
    y += 4;
    paragraph(text, 15, "#24695a");
  }
  const images: ScreenEvent[] = [];
  const numbers = new Map<string, number>();
  function evidence(item: SummaryItem) {
    const resolved = resolveSummaryEvidence(item, transcripts, screens);
    const refs = resolved.screens.map(({ screen }) => {
      if (!numbers.has(screen.id)) numbers.set(screen.id, images.push(screen));
      return `図${numbers.get(screen.id)}`;
    });
    if (refs.length) paragraph(`関連画面　${refs.join("、")}`, 10, "#45665e");
    for (const speech of resolved.transcripts) paragraph(`［${timestamp(speech.startedAtMs)}］ ${speech.text}`, 10, "#45665e");
    if (resolved.missingCount) paragraph(`取得できない根拠：${resolved.missingCount}件`, 10);
  }
  paragraph(meetingStartStamp(meeting), 10);
  paragraph(meetingName(meeting), 21);
  heading("要約");
  paragraph(summary.summary);
  if (summary.topics.length) paragraph(summary.topics.join(" ／ "), 10);
  evidence({ text: summary.summary, evidenceIds: summary.overviewEvidenceIds ?? [] });
  for (const discussion of summary.discussions ?? []) {
    heading(discussion.title);
    paragraph(discussion.summary);
    evidence({ text: discussion.summary, evidenceIds: discussion.evidenceIds });
  }
  for (const [label, items] of [["決定事項", summary.decisions], ["未決事項", summary.openQuestions], ["アクションアイテム", summary.actionItems]] as const) {
    if (!items.length) continue;
    heading(label);
    items.forEach((item, index) => {
      paragraph(`${index + 1}. ${item.text}`);
      if (item.assignee) paragraph(`担当：${item.assignee}`, 10);
      if (item.dueAt) paragraph(`期限：${item.dueAt}`, 10);
      evidence(item);
    });
  }
  if (summary.speakerAttributions?.length) {
    heading("発話者の照合（AIによる候補）");
    for (const speaker of summary.speakerAttributions) {
      paragraph(`${speaker.name}　${speaker.reason}`);
      evidence({ text: speaker.name, evidenceIds: [speaker.transcriptId, ...speaker.evidenceIds] });
    }
  }
  if (images.length) {
    pdf.addPage();
    y = 23;
    heading("関連するスクリーンショット");
    paragraph("図番号は本文の関連画面に対応します。発話中に表示されていた画面も含みます。", 10);
    for (const [index, screen] of images.entries()) {
      let canvas: HTMLCanvasElement;
      try { canvas = await screenshot(screen); }
      catch { throw new Error(`図${index + 1}（${timestamp(screen.startedAtMs)}）を読み込めません。再試行してください。`); }
      const scale = Math.min(width / canvas.width, 175 / canvas.height);
      const height = canvas.height * scale;
      room(height + 13);
      paragraph(`図${index + 1}　${timestamp(screen.startedAtMs)}`, 12);
      pdf.addImage(canvas.toDataURL("image/jpeg", 0.9), "JPEG", 18, y, canvas.width * scale, height);
      y += height + 6;
      if (screen.description) paragraph(screen.description, 10);
    }
  }
  const pages = pdf.getNumberOfPages();
  for (let i = 1; i <= pages; i++) {
    pdf.setPage(i);
    pdf.setTextColor("#52645f");
    pdf.setFontSize(9);
    pdf.text(`${i} / ${pages}`, 192, 287, { align: "right" });
  }
  const filename = summaryFilename(meeting, "pdf");
  const native = (window as Window & { webkit?: { messageHandlers?: {
    saveSummaryPDF?: { postMessage(payload: { filename: string; pdf: string }): void };
  } } }).webkit?.messageHandlers?.saveSummaryPDF;
  if (native) native.postMessage({ filename, pdf: await base64(pdf.output("blob")) });
  else pdf.save(filename);
}
