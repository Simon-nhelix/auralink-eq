import assert from "node:assert/strict";
import test from "node:test";

import { summarizeTuningPreferences } from "../dist/store.js";

const baseEntry = {
  id: "fb_x",
  createdAt: "2026-07-03T00:00:00.000Z",
};

test("summarizeTuningPreferences counts sentiments and ranks disliked issues", () => {
  const entries = [
    { ...baseEntry, id: "1", headphone: "Sennheiser HD600", sentiment: "disliked", perceivedIssue: "harsh", goal: "brighter" },
    { ...baseEntry, id: "2", headphone: "Sennheiser HD600", sentiment: "disliked", perceivedIssue: "harsh", goal: "brighter" },
    { ...baseEntry, id: "3", headphone: "Sennheiser HD600", sentiment: "disliked", perceivedIssue: "sibilant" },
    { ...baseEntry, id: "4", headphone: "Sennheiser HD600", sentiment: "liked", perceivedIssue: "good_balance", goal: "warmer" },
    { ...baseEntry, id: "5", headphone: "Sennheiser HD600", sentiment: "mixed", tags: ["less-treble-bite", "less-treble-bite", "likes-warm-low-mids"] },
  ];

  const summary = summarizeTuningPreferences(entries, { headphoneNeedle: "hd600", limit: 3 });

  assert.equal(summary.scope, "headphone");
  assert.equal(summary.totalEntries, 5);
  assert.equal(summary.headphone, "hd600");
  assert.deepEqual(summary.sentimentCounts, { liked: 1, disliked: 3, mixed: 1 });

  // harshest complaint ranks first (x2), then sibilant (x1).
  assert.equal(summary.topDislikedIssues[0].issue, "harsh");
  assert.equal(summary.topDislikedIssues[0].count, 2);
  assert.equal(summary.topDislikedIssues[1].issue, "sibilant");

  // Liked issue surfaces separately.
  assert.equal(summary.topLikedIssues[0].issue, "good_balance");

  // Goals aggregate by sentiment.
  assert.equal(summary.dislikedGoals[0].goal, "brighter");
  assert.equal(summary.dislikedGoals[0].count, 2);
  assert.equal(summary.likedGoals[0].goal, "warmer");

  // Tag frequency dedupes and ranks.
  assert.equal(summary.tagFrequency[0].tag, "less-treble-bite");
  assert.equal(summary.tagFrequency[0].count, 2);

  // derivedNotes mentions the avoid list.
  assert.ok(summary.derivedNotes.some((n) => /Avoid:/.test(n)));
  assert.ok(summary.derivedNotes.some((n) => /Preference markers:/.test(n)));

  // recent respects limit.
  assert.equal(summary.recent.length, 3);
  assert.equal(summary.recent[0].id, "1"); // newest-first = insertion order here
});

test("summarizeTuningPreferences with no data returns an honest empty summary", () => {
  const summary = summarizeTuningPreferences([], {});
  assert.equal(summary.scope, "global");
  assert.equal(summary.totalEntries, 0);
  assert.deepEqual(summary.sentimentCounts, { liked: 0, disliked: 0, mixed: 0 });
  assert.equal(summary.topDislikedIssues.length, 0);
  assert.ok(summary.derivedNotes.some((n) => /No feedback recorded yet/.test(n)));
});

test("summarizeTuningPreferences scopes by headphone and ignores unrelated entries", () => {
  const entries = [
    { ...baseEntry, id: "1", headphone: "Sennheiser HD600", sentiment: "liked" },
    { ...baseEntry, id: "2", headphone: "Moondrop Aria", sentiment: "disliked", perceivedIssue: "harsh" },
  ];
  const hd600 = summarizeTuningPreferences(entries, { headphoneNeedle: "hd600" });
  assert.equal(hd600.totalEntries, 1);
  assert.equal(hd600.sentimentCounts.liked, 1);
  assert.equal(hd600.sentimentCounts.disliked, 0);

  const global = summarizeTuningPreferences(entries, {});
  assert.equal(global.totalEntries, 2);
});
