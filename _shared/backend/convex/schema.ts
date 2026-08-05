import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  rooms: defineTable({
    name: v.string(),
    count: v.number(),
    lastLanguage: v.union(v.string(), v.null()),
    latestRunId: v.union(v.string(), v.null()),
    updatedAt: v.number(),
  }).index("by_name", ["name"]),
  events: defineTable({
    room: v.string(),
    runId: v.string(),
    language: v.string(),
    createdAt: v.number(),
  })
    .index("by_room_and_run_id", ["room", "runId"])
    .index("by_room", ["room"]),
});
