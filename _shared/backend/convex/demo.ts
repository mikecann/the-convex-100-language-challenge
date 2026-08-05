import { ConvexError, v } from "convex/values";
import { action, mutation, query } from "./_generated/server";

const stateValidator = v.object({
  room: v.string(),
  count: v.number(),
  lastLanguage: v.union(v.string(), v.null()),
  latestRunId: v.union(v.string(), v.null()),
  updatedAt: v.union(v.number(), v.null()),
});

const zeroState = (room: string) => ({
  room,
  count: 0,
  lastLanguage: null,
  latestRunId: null,
  updatedAt: null,
});

export const state = query({
  args: { room: v.string() },
  returns: stateValidator,
  handler: async (ctx, args) => {
    const room = await ctx.db
      .query("rooms")
      .withIndex("by_name", (q) => q.eq("name", args.room))
      .unique();

    if (room === null) {
      return zeroState(args.room);
    }

    return {
      room: room.name,
      count: room.count,
      lastLanguage: room.lastLanguage,
      latestRunId: room.latestRunId,
      updatedAt: room.updatedAt,
    };
  },
});

export const requiresNonzero = query({
  args: { room: v.string() },
  returns: stateValidator,
  handler: async (ctx, args) => {
    const room = await ctx.db
      .query("rooms")
      .withIndex("by_name", (q) => q.eq("name", args.room))
      .unique();

    if (room === null || room.count === 0) {
      throw new ConvexError({
        code: "ROOM_EMPTY",
        message: "Increment the room to repair this reactive query",
      });
    }

    return {
      room: room.name,
      count: room.count,
      lastLanguage: room.lastLanguage,
      latestRunId: room.latestRunId,
      updatedAt: room.updatedAt,
    };
  },
});

export const increment = mutation({
  args: {
    room: v.string(),
    language: v.string(),
    runId: v.string(),
  },
  returns: v.object({
    applied: v.boolean(),
    state: stateValidator,
  }),
  handler: async (ctx, args) => {
    const existingEvent = await ctx.db
      .query("events")
      .withIndex("by_room_and_run_id", (q) =>
        q.eq("room", args.room).eq("runId", args.runId),
      )
      .unique();
    const existingRoom = await ctx.db
      .query("rooms")
      .withIndex("by_name", (q) => q.eq("name", args.room))
      .unique();

    if (existingEvent !== null) {
      return {
        applied: false,
        state:
          existingRoom === null
            ? zeroState(args.room)
            : {
                room: existingRoom.name,
                count: existingRoom.count,
                lastLanguage: existingRoom.lastLanguage,
                latestRunId: existingRoom.latestRunId,
                updatedAt: existingRoom.updatedAt,
              },
      };
    }

    const now = Date.now();
    const nextState = {
      room: args.room,
      count: (existingRoom?.count ?? 0) + 1,
      lastLanguage: args.language,
      latestRunId: args.runId,
      updatedAt: now,
    };

    if (existingRoom === null) {
      await ctx.db.insert("rooms", {
        name: nextState.room,
        count: nextState.count,
        lastLanguage: nextState.lastLanguage,
        latestRunId: nextState.latestRunId,
        updatedAt: nextState.updatedAt,
      });
    } else {
      await ctx.db.patch(existingRoom._id, {
        count: nextState.count,
        lastLanguage: nextState.lastLanguage,
        latestRunId: nextState.latestRunId,
        updatedAt: nextState.updatedAt,
      });
    }

    await ctx.db.insert("events", {
      room: args.room,
      runId: args.runId,
      language: args.language,
      createdAt: now,
    });

    return { applied: true, state: nextState };
  },
});

export const greet = action({
  args: { language: v.string() },
  returns: v.object({ language: v.string(), message: v.string() }),
  handler: async (_ctx, args) => ({
    language: args.language,
    message: `Hello, ${args.language}. Convex is responding.`,
  }),
});

export const echo = query({
  args: { value: v.any() },
  returns: v.any(),
  handler: async (_ctx, args) => {
    console.log("demo:echo received a JSON-safe value");
    return args.value;
  },
});

export const fail = query({
  args: { code: v.string() },
  returns: v.null(),
  handler: async (_ctx, args) => {
    throw new ConvexError({
      code: args.code,
      message: "Intentional conformance failure",
    });
  },
});
