import { useEffect, useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, isAuthenticationError, subscribe } from "./api";
import type { MeetingStatus, ScreenEvent, ServerEvent, Settings, TranscriptEvent, TranscriptionProgress } from "./types";

type Page = "home" | "meetings" | "detail" | "settings";
const labels: Record<MeetingStatus, string> = { idle: "待機", capturing: "収録中", finalizing: "確定中", analyzing: "解析中", completed: "完了", interrupted: "中断", failed: "失敗", partially_completed: "一部完了" };
const formatTime = (ms?: number) => { const seconds = Math.floor((ms ?? 0) / 1000); return `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`; };
const duration = (startedAt: string, endedAt?: string | null) => Math.max(0, new Date(endedAt ?? Date.now()).getTime() - new Date(startedAt).getTime());
const date = (value: string) => new Intl.DateTimeFormat("ja-JP", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(new Date(value));

function StatusBadge({ status }: { status: MeetingStatus }) { return <span className={`badge ${status}`}>{labels[status]}</span>; }
function Empty({ children }: { children: React.ReactNode }) { return <div className="empty">{children}</div>; }
function ErrorBox({ error }: { error: Error }) { return <div className="error-box"><strong>{isAuthenticationError(error) ? "セッションの有効期限が切れました" : "読み込みに失敗しました"}</strong><span>{isAuthenticationError(error) ? "Meeting Agentアプリの「Open Web UI」から開き直してください。" : error.message}</span></div>; }

export function App() {
  const client = useQueryClient();
  const [page, setPage] = useState<Page>("home");
  const [meetingId, setMeetingId] = useState<string>();
  const [connected, setConnected] = useState(false);
  const [notice, setNotice] = useState<string>();
  useEffect(() => subscribe((event: ServerEvent) => {
    if (event.type === "error") setNotice(event.payload.message);
    void client.invalidateQueries({ queryKey: ["capture"] });
    void client.invalidateQueries({ queryKey: ["meetings"] });
    if ("meetingId" in event) void client.invalidateQueries({ queryKey: ["meeting", event.meetingId] });
  }, setConnected), [client]);
  const openMeeting = (id: string) => { setMeetingId(id); setPage("detail"); };
  return <div className="shell">
    <aside>
      <div className="brand"><span className="brand-mark">M</span><div>Meeting Agent<small>Local workspace</small></div></div>
      <nav>
        <button className={page === "home" ? "active" : ""} onClick={() => setPage("home")}><span>●</span>ホーム</button>
        <button className={page === "meetings" || page === "detail" ? "active" : ""} onClick={() => setPage("meetings")}><span>▤</span>ミーティング</button>
        <button className={page === "settings" ? "active" : ""} onClick={() => setPage("settings")}><span>⚙</span>設定</button>
      </nav>
      <div className="connection"><i className={connected ? "online" : ""} />{connected ? "Local Agent 接続済み" : "再接続しています…"}</div>
    </aside>
    <main>{notice && <div className="notice">{notice}<button onClick={() => setNotice(undefined)}>×</button></div>}
      {page === "home" && <Home openMeeting={openMeeting} />}
      {page === "meetings" && <MeetingList openMeeting={openMeeting} />}
      {page === "detail" && meetingId && <MeetingDetail id={meetingId} back={() => setPage("meetings")} />}
      {page === "settings" && <SettingsPage />}
    </main>
  </div>;
}

function Home({ openMeeting }: { openMeeting: (id: string) => void }) {
  const client = useQueryClient();
  const capture = useQuery({ queryKey: ["capture"], queryFn: api.captureStatus, refetchInterval: 5000 });
  const meetings = useQuery({ queryKey: ["meetings"], queryFn: api.meetings });
  const start = useMutation({ mutationFn: () => api.startCapture(), onSuccess: () => void client.invalidateQueries({ queryKey: ["capture"] }) });
  const stop = useMutation({ mutationFn: api.stopCapture, onSuccess: () => void client.invalidateQueries({ queryKey: ["capture"] }) });
  const isLive = capture.data?.status === "capturing";
  const activeMeeting = meetings.data?.find((m) => m.id === capture.data?.meetingId);
  return <><header><div><p className="eyebrow">TODAY</p><h1>会議の記憶を、手元に。</h1><p>発話と画面をひとつのタイムラインに記録します。</p></div></header>
    {capture.error ? <ErrorBox error={capture.error} /> : <section className={`capture-card ${isLive ? "live" : ""}`}>
      <div><span className="live-dot" /><div><p>{isLive ? "CAPTURING NOW" : "READY TO CAPTURE"}</p><h2>{isLive ? activeMeeting?.title ?? "新しいミーティング" : "Captureを開始できます"}</h2><span>{isLive ? `${activeMeeting ? formatTime(duration(activeMeeting.startedAt)) : "--:--"} · ${capture.data?.videoFrames ?? 0} frames · 音声と画面を保存中` : "データはこのMac内に保存されます"}</span></div></div>
      <div className="capture-actions">{isLive && capture.data?.meetingId && <button className="ghost" onClick={() => openMeeting(capture.data!.meetingId!)}>ライブ表示</button>}<button className={isLive ? "stop" : "primary"} disabled={start.isPending || stop.isPending} onClick={() => isLive ? stop.mutate() : start.mutate()}>{isLive ? "■  停止" : "●  Capture開始"}</button></div>
    </section>}
    <div className="section-title"><div><h2>最近のミーティング</h2><p>ローカルに保存されたEvidence</p></div><button className="text-button" onClick={() => document.querySelector("nav button:nth-child(2)") instanceof HTMLElement && (document.querySelector("nav button:nth-child(2)") as HTMLElement).click()}>すべて表示 →</button></div>
    <MeetingCards meetings={meetings.data ?? []} loading={meetings.isLoading} openMeeting={openMeeting} />
  </>;
}

function MeetingCards({ meetings, loading, openMeeting }: { meetings: Awaited<ReturnType<typeof api.meetings>>; loading: boolean; openMeeting: (id: string) => void }) {
  if (loading) return <div className="skeleton-grid"><i/><i/><i/></div>;
  if (!meetings.length) return <Empty>まだミーティングはありません。</Empty>;
  return <div className="meeting-grid">{meetings.map((m) => <button className="meeting-card" key={m.id} onClick={() => openMeeting(m.id)}><div><StatusBadge status={m.status}/><span>{date(m.startedAt)}</span></div><h3>{m.title || "名称未設定のミーティング"}</h3><p>{formatTime(duration(m.startedAt, m.endedAt))} · Timeline Evidence</p><span className="arrow">↗</span></button>)}</div>;
}

function MeetingList({ openMeeting }: { openMeeting: (id: string) => void }) {
  const query = useQuery({ queryKey: ["meetings"], queryFn: api.meetings });
  const [filter, setFilter] = useState("");
  const rows = query.data?.filter((m) => (m.title ?? "").toLowerCase().includes(filter.toLowerCase())) ?? [];
  return <><header><div><p className="eyebrow">LIBRARY</p><h1>ミーティング</h1><p>取得済みのTimelineとEvidenceを確認できます。</p></div><input className="search" aria-label="ミーティングを検索" placeholder="タイトルを検索" value={filter} onChange={(e) => setFilter(e.target.value)} /></header>
    {query.error ? <ErrorBox error={query.error}/> : <MeetingCards meetings={rows} loading={query.isLoading} openMeeting={openMeeting}/>}</>;
}

function MeetingDetail({ id, back }: { id: string; back: () => void }) {
  const client = useQueryClient();
  const [tab, setTab] = useState<"timeline" | "summary">("timeline");
  const [focusScreen, setFocusScreen] = useState<string>();
  const [focusTranscript, setFocusTranscript] = useState<string>();
  const meeting = useQuery({ queryKey: ["meeting", id], queryFn: () => api.meeting(id) });
  const transcript = useQuery({ queryKey: ["meeting", id, "transcript"], queryFn: () => api.transcript(id) });
  const screens = useQuery({ queryKey: ["meeting", id, "screens"], queryFn: () => api.screens(id) });
  const transcriptionProgress = useQuery({
    queryKey: ["meeting", id, "transcription-progress"], queryFn: () => api.transcriptionProgress(id),
    refetchInterval: (query) => ["queued", "running", "retrying"].includes(query.state.data?.state ?? "") ? 1_000 : false,
  });
  const retryTranscription = useMutation({
    mutationFn: () => api.retryTranscription(id),
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: ["meeting", id, "transcription-progress"] });
      void client.invalidateQueries({ queryKey: ["meeting", id, "transcript"] });
    },
  });
  const summary = useQuery({
    queryKey: ["meeting", id, "summary"], queryFn: () => api.summary(id), enabled: tab === "summary",
    retry: 1, refetchInterval: (query) => query.state.data == null ? 2_000 : false,
  });
  const summaryProgress = useQuery({
    queryKey: ["meeting", id, "summary-progress"], queryFn: () => api.summaryProgress(id), enabled: tab === "summary",
    refetchInterval: (query) => ["completed", "failed"].includes(query.state.data?.state ?? "") ? false : 1_000,
  });
  const summarize = useMutation({
    mutationFn: () => api.summarize(id),
    onSuccess: () => {
      void client.invalidateQueries({ queryKey: ["meeting", id, "summary"] });
      void client.invalidateQueries({ queryKey: ["meeting", id, "summary-progress"] });
    },
  });
  if (meeting.error) return <ErrorBox error={meeting.error}/>;
  return <><button className="back" onClick={back}>← ミーティング一覧</button><header className="detail-header"><div>{meeting.data && <StatusBadge status={meeting.data.status}/>}<h1>{meeting.data?.title ?? "読み込み中…"}</h1><p>{meeting.data ? date(meeting.data.startedAt) : ""} · {meeting.data ? formatTime(duration(meeting.data.startedAt, meeting.data.endedAt)) : ""}</p></div></header>
    {meeting.data && ["interrupted", "failed", "partially_completed"].includes(meeting.data.status) && <div className="evidence-warning"><strong>一部の処理が完了していません</strong><span>取得済みのTranscriptとScreen Evidenceは引き続き閲覧できます。</span></div>}
    <div className="tabs"><button className={tab === "timeline" ? "active" : ""} onClick={() => setTab("timeline")}>Timeline</button><button className={tab === "summary" ? "active" : ""} onClick={() => setTab("summary")}>Summary</button></div>
    {tab === "timeline" ? <><TranscriptionRecovery value={transcriptionProgress.data} transcriptCount={transcript.data?.length ?? 0} retrying={retryTranscription.isPending} error={retryTranscription.error} onRetry={() => retryTranscription.mutate()}/><div className="timeline-layout"><TranscriptPanel items={transcript.data ?? []} loading={transcript.isLoading} focus={focusTranscript} onScreen={(screenId) => { setFocusScreen(screenId); document.getElementById(`screen-${screenId}`)?.scrollIntoView({ behavior: "smooth" }); }}/><ScreensPanel items={screens.data ?? []} loading={screens.isLoading} focus={focusScreen} onTranscript={(screenId) => { const hit = transcript.data?.find((t) => t.screenRefs.some((ref) => ref.screenId === screenId)); if (hit) { setFocusTranscript(hit.id); document.getElementById(`transcript-${hit.id}`)?.scrollIntoView({ behavior: "smooth" }); } }}/></div></> : <SummaryPanel value={summary.data} progress={summaryProgress.data} loading={summary.isLoading || summaryProgress.isLoading} error={summary.error ?? summaryProgress.error ?? summarize.error} generating={summarize.isPending} onGenerate={() => summarize.mutate()}/>}</>;
}

function TranscriptionRecovery({ value, transcriptCount, retrying, error, onRetry }: { value?: TranscriptionProgress; transcriptCount: number; retrying: boolean; error: Error | null; onRetry: () => void }) {
  if (!value) return null;
  const hasAudio = value.hasSystemAudio || value.hasMicrophoneAudio;
  const active = ["queued", "running", "retrying"].includes(value.state);
  const size = value.archivedBytes < 1_048_576 ? `${Math.round(value.archivedBytes / 1024)} KB` : `${(value.archivedBytes / 1_048_576).toFixed(1)} MB`;
  return <div className={`transcription-recovery ${value.state}`}><div><strong>{active ? "保存した音声から文字起こしを再処理しています" : hasAudio ? `復旧用音声をローカル保存済み（${size}）` : "復旧用音声はありません"}</strong><span>{value.state === "retrying" ? `一時エラーのため自動再試行待ち（${value.retryCount}回）` : value.state === "failed" ? "自動処理に失敗しました。音声は残っているため再実行できます。" : transcriptCount === 0 && hasAudio ? "文字起こしがない場合は保存音声から再実行できます。" : "システム音声とマイク音声を会議データと一緒に保持しています。"}</span>{(value.error || error) && <small>{value.error ?? error?.message}</small>}</div>{hasAudio && !active && <button className="primary" disabled={retrying} onClick={onRetry}>{retrying ? "依頼中…" : transcriptCount ? "文字起こしを再実行" : "文字起こしを復旧"}</button>}</div>;
}

function TranscriptPanel({ items, loading, focus, onScreen }: { items: TranscriptEvent[]; loading: boolean; focus?: string; onScreen: (id: string) => void }) {
  return <section className="panel"><div className="panel-title"><h2>Transcript</h2><span>{items.length} events</span></div>{loading ? <Empty>読み込み中…</Empty> : !items.length ? <Empty>Transcriptはまだありません。</Empty> : <div className="transcript-list">{items.map((item) => <article id={`transcript-${item.id}`} className={focus === item.id ? "focused" : ""} key={`${item.id}-${item.revision}`}><time>{formatTime(item.startedAtMs)}</time><div><div className="speaker"><b>{item.speaker === "self" ? "あなた" : item.speaker === "remote" ? "参加者" : "話者不明"}</b>{!item.isFinal && <span className="partial">文字起こし中…</span>}</div><p>{item.text}</p>{item.screenRefs.length > 0 && <div className="refs">{item.screenRefs.map((ref) => <button key={`${ref.screenId}-${ref.relation}`} onClick={() => onScreen(ref.screenId)}>▧ {ref.screenId} <small>{Math.round((ref.confidence ?? 0) * 100)}%</small></button>)}</div>}</div></article>)}</div>}</section>;
}
function ScreensPanel({ items, loading, focus, onTranscript }: { items: ScreenEvent[]; loading: boolean; focus?: string; onTranscript: (id: string) => void }) {
  return <section className="panel screens"><div className="panel-title"><h2>Screen Timeline</h2><span>{items.length} frames</span></div>{loading ? <Empty>読み込み中…</Empty> : !items.length ? <Empty>画面Evidenceはまだありません。</Empty> : items.map((item) => <article id={`screen-${item.id}`} className={focus === item.id ? "screen-item focused" : "screen-item"} key={item.id}><AuthenticatedImage path={item.imageUrl} alt={item.description ?? item.id}/><div><time>{formatTime(item.startedAtMs)}</time><h3>{item.description ?? "画面を解析中"}</h3>{item.analysisStatus === "running" && <span className="processing">◌ 解析中</span>}{item.analysisStatus === "failed" && <span className="failed-text">解析失敗 · 画像は保存済み</span>}<p>{item.ocr}</p><button className="text-button" onClick={() => onTranscript(item.id)}>関連する発話を見る →</button></div></article>)}</section>;
}

function AuthenticatedImage({ path, alt }: { path: string; alt: string }) {
  const image = useQuery({ queryKey: ["screen-image", path], queryFn: () => api.screenImage(path), staleTime: Infinity });
  const objectUrl = useMemo(() => image.data ? URL.createObjectURL(image.data) : undefined, [image.data]);
  useEffect(() => () => { if (objectUrl) URL.revokeObjectURL(objectUrl); }, [objectUrl]);
  if (image.isLoading) return <div className="screen-image-state">画像を読み込み中…</div>;
  if (image.isError || !objectUrl) return <div className="screen-image-state error">画像を表示できません</div>;
  return <img src={objectUrl} alt={alt}/>;
}
function SummaryPanel({ value, progress, loading, error, generating, onGenerate }: { value: Awaited<ReturnType<typeof api.summary>> | undefined; progress: Awaited<ReturnType<typeof api.summaryProgress>> | undefined; loading: boolean; error: Error | null; generating: boolean; onGenerate: () => void }) {
  if (loading) return <Empty>要約を確認しています…</Empty>;
  if (error) return <div className="error-box"><strong>要約の取得に失敗しました</strong><span>{error.message}</span><button className="primary" onClick={onGenerate} disabled={generating}>{generating ? "再生成を依頼中…" : "要約を再生成"}</button></div>;
  if (!value) {
    const messages = { not_started: "要約はまだ開始されていません。", queued: "要約は処理待ちです。", running: "文字起こしと画面情報から要約を生成しています。", retrying: `一時的な失敗のため再試行を待っています（${progress?.retryCount ?? 0}回）。`, completed: "要約結果を読み込んでいます。", failed: "要約の生成に失敗しました。" };
    const state = progress?.state ?? "not_started";
    return <div className={`summary-progress ${state}`}><span className="progress-dot"/><strong>{messages[state]}</strong>{progress?.error && <small>{progress.error}</small>}{["not_started", "failed"].includes(state) && <button className="primary" onClick={onGenerate} disabled={generating}>{generating ? "生成を依頼中…" : state === "failed" ? "要約を再生成" : "今すぐ要約を生成"}</button>}</div>;
  }
  return <div className="summary"><section><p className="eyebrow">OVERVIEW</p><h2>要約</h2><p className="summary-copy">{value.summary}</p><div className="topics">{value.topics.map((topic) => <span key={topic}>{topic}</span>)}</div></section><div className="summary-columns"><SummaryList title="決定事項" marker="✓" items={value.decisions}/><SummaryList title="未決事項" marker="?" items={value.openQuestions}/><section><h2>Action Items</h2>{value.actionItems.map((item) => <div className="action" key={item.text}><span>→</span><div><b>{item.text}</b><small>{item.assignee ?? "担当者未定"}{item.dueAt ? ` · ${date(item.dueAt)}` : ""}</small></div></div>)}</section></div></div>;
}
function SummaryList({ title, marker, items }: { title: string; marker: string; items: { text: string }[] }) { return <section><h2>{title}</h2>{items.map((item) => <div className="summary-item" key={item.text}><span>{marker}</span>{item.text}</div>)}</section>; }

function SettingsPage() {
  const client = useQueryClient(); const query = useQuery({ queryKey: ["settings"], queryFn: api.settings }); const [draft, setDraft] = useState<Settings>();
  useEffect(() => { if (query.data) setDraft(query.data); }, [query.data]);
  const save = useMutation({ mutationFn: api.saveSettings, onSuccess: (data) => { client.setQueryData(["settings"], data); } });
  const changed = useMemo(() => draft && JSON.stringify(draft) !== JSON.stringify(query.data), [draft, query.data]);
  return <><header><div><p className="eyebrow">PREFERENCES</p><h1>設定</h1><p>処理Providerとローカルデータの保持期間を管理します。</p></div></header>{draft && <div className="settings-form"><label><span><b>文字起こし</b><small>音声はローカルで処理されます</small></span><select value={draft.sttProvider} onChange={(e) => setDraft({ ...draft, sttProvider: e.target.value as Settings["sttProvider"] })}><option value="apple_speech">Apple Speech (On-device)</option></select></label><label><span><b>要約Provider</b><small>Codex利用時は送信前に確認します</small></span><select value={draft.summaryProvider} onChange={(e) => setDraft({ ...draft, summaryProvider: e.target.value as Settings["summaryProvider"] })}><option value="apple_foundation_models">Apple Foundation Models</option><option value="codex">Codex (Optional)</option></select></label><label><span><b>保持期間</b><small>期限を過ぎた会議データを削除します</small></span><select value={draft.retentionDays} onChange={(e) => setDraft({ ...draft, retentionDays: Number(e.target.value) })}><option value={7}>7日</option><option value={30}>30日</option><option value={90}>90日</option><option value={365}>1年</option></select></label><label><span><b>文字起こし復旧</b><small>システム音声とマイク音声を会議フォルダへ常時保存します</small></span><b>常時ON</b></label><button className="primary save" disabled={!changed || save.isPending} onClick={() => draft && save.mutate(draft)}>{save.isSuccess && !changed ? "保存しました ✓" : "設定を保存"}</button></div>}</>;
}
