import assert from "node:assert/strict";
import test from "node:test";
import {
  semanticDocumentResultSchema,
  semanticDocumentUserPrompt,
  semanticIndexSourceSchema
} from "./semantic-contract.js";

const validSource = {
  itemID: "00000000-0000-4000-8000-000000000001",
  contentHash: "contract",
  capturedAt: 1_754_223_296,
  sourceApplicationName: "Notes",
  sourceBundleIdentifier: "com.apple.Notes",
  contentType: "text",
  text: "Release v1.3",
  files: []
};

test("source contract accepts epoch seconds and exposes ISO capturedAt only to the model", () => {
  const source = semanticIndexSourceSchema.parse(validSource);
  assert.match(semanticDocumentUserPrompt(source), /"capturedAt":"2025-08-03T12:14:56\.000Z"/);
  assert.throws(() => semanticIndexSourceSchema.parse({ ...validSource, capturedAt: "2025-08-03T12:14:56Z" }));
});

test("document contract requires exactly all eight keys", () => {
  const valid = {
    modality: "text",
    summary: "Release v1.3",
    keywords: [], aliases: [], entities: [], visualTextHints: [], searchIntents: [], language: "en"
  };
  assert.deepEqual(semanticDocumentResultSchema.parse(valid), valid);
  assert.throws(() => semanticDocumentResultSchema.parse({ ...valid, language: undefined }));
  assert.throws(() => semanticDocumentResultSchema.parse({ ...valid, profile: "owner likes releases" }));
});
