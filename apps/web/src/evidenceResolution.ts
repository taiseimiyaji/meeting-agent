import type { ScreenEvent, ScreenRelation, SummaryItem, TranscriptEvent } from "./types";

export function resolveSummaryEvidence(item: SummaryItem, transcripts: TranscriptEvent[], screens: ScreenEvent[]) {
  const transcriptById = new Map(transcripts.map((value) => [value.id, value]));
  const screenById = new Map(screens.map((value) => [value.id, value]));
  const speech = new Map<string, TranscriptEvent>();
  const images = new Map<string, { screen: ScreenEvent; relations: Set<ScreenRelation | "summary_evidence"> }>();
  const missing = new Set<string>();
  function addImage(id: string, relation: ScreenRelation | "summary_evidence") {
    const screen = screenById.get(id);
    if (!screen) { missing.add(id); return; }
    const entry = images.get(id) ?? { screen, relations: new Set<ScreenRelation | "summary_evidence">() };
    entry.relations.add(relation);
    images.set(id, entry);
  }
  for (const id of item.evidenceIds) {
    const transcript = transcriptById.get(id);
    if (transcript) {
      speech.set(id, transcript);
      for (const reference of transcript.screenRefs) addImage(reference.screenId, reference.relation);
    } else if (screenById.has(id)) {
      addImage(id, "summary_evidence");
    } else {
      missing.add(id);
    }
  }
  return {
    transcripts: [...speech.values()].sort((a, b) => a.startedAtMs - b.startedAtMs),
    screens: [...images.values()].sort((a, b) => a.screen.startedAtMs - b.screen.startedAtMs),
    missingCount: missing.size,
  };
}
