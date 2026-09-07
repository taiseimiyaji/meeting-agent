import { useEffect, useRef, useState } from "react";
import { AuthenticatedImage } from "./AuthenticatedImage";
import { resolveSummaryEvidence } from "./evidenceResolution";
import type { ScreenEvent, SummaryItem, TranscriptEvent } from "./types";

const relationLabels = {
  visible_during_speech: "発話中に表示", previously_visible: "発話より前に表示",
  explicitly_referenced: "発話から参照", summary_evidence: "要約の根拠画面",
};
const time = (ms: number) => `${String(Math.floor(ms / 60000)).padStart(2, "0")}:${String(Math.floor(ms / 1000) % 60).padStart(2, "0")}`;

export function SummaryEvidence({ item, transcripts, screens }: { item: SummaryItem; transcripts: TranscriptEvent[]; screens: ScreenEvent[] }) {
  const evidence = resolveSummaryEvidence(item, transcripts, screens);
  const [expanded, setExpanded] = useState<ScreenEvent>();
  return <div className="summary-evidence">
    {evidence.screens.length > 0 ? <div className="summary-evidence-images">{evidence.screens.map(({ screen, relations }) => <figure key={screen.id}>
      <button className="screenshot-preview" onClick={() => setExpanded(screen)} aria-label={`${time(screen.startedAtMs)}の画面を拡大`}>
        <AuthenticatedImage path={screen.imageUrl} alt={screen.description ?? `${time(screen.startedAtMs)}のスクリーンショット`}/>
      </button>
      <figcaption><time>{time(screen.startedAtMs)}</time> · {[...relations].map((relation) => relationLabels[relation]).join(" / ")}{screen.description && <p>{screen.description}</p>}</figcaption>
    </figure>)}</div> : <p className="evidence-note">この項目に紐づく画面はありません。</p>}
    {evidence.transcripts.length > 0 && <details className="summary-speech"><summary>根拠の発話を見る（{evidence.transcripts.length}件）</summary>{evidence.transcripts.map((transcript) => <blockquote key={transcript.id}><small>{time(transcript.startedAtMs)} · {transcript.attributedSpeaker ? `${transcript.attributedSpeaker.name}（AI照合）` : transcript.speaker === "self" ? "あなた" : transcript.speaker === "remote" ? "話者不明（システム音声）" : "話者不明"}</small><p>{transcript.text}</p></blockquote>)}</details>}
    {evidence.missingCount > 0 && <p className="evidence-note">一部の根拠データが見つかりません（{evidence.missingCount}件）。</p>}
    {expanded && <ScreenshotDialog screen={expanded} close={() => setExpanded(undefined)}/>}
  </div>;
}

function ScreenshotDialog({ screen, close }: { screen: ScreenEvent; close: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => { const element = dialog.current; element?.showModal(); return () => element?.close(); }, []);
  return <dialog ref={dialog} className="screenshot-dialog" aria-label="スクリーンショットの拡大" onCancel={close}>
    <header><strong>{time(screen.startedAtMs)} · {screen.description ?? "会議の画面"}</strong><button autoFocus onClick={close}>閉じる</button></header>
    <AuthenticatedImage path={screen.imageUrl} alt={screen.description ?? "会議のスクリーンショット"}/>
  </dialog>;
}
