function apiError(status, code) {
  const error = new ApiError(status, code);
  // PocketBase's constructor sentence-cases messages; these are wire codes.
  error.message = code;
  return error;
}
function requireAccount(app, owner) {
  const rows = app.findRecordsByFilter("users", "id={:owner}", "", 1, 0, {owner});
  if (!rows.length) throw apiError(401, "account_not_found");
}
function first(app, collection, filter, params) {
  const rows = app.findRecordsByFilter(collection, filter, "", 1, 0, params);
  return rows.length ? rows[0] : null;
}
function state(app, owner) {
  return first(app, "gsd_dataset_state", "owner={:owner}", {owner});
}
function generation(app, owner) {
  const record = state(app, owner);
  return record ? record.getString("generation") : "0";
}
function validToken(value) {
  if (typeof value !== "string" || !value.length) return false;
  let bytes = 0;
  for (const character of value) {
    const point = character.codePointAt(0);
    if (point < 32 || point === 127 || (point >= 0xd800 && point <= 0xdfff)) return false;
    bytes += point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
    if (bytes > 128) return false;
  }
  return true;
}
function deleteTasks(app, owner) {
  let count = 0;
  for (;;) {
    const rows = app.findRecordsByFilter("tasks", "owner={:owner}", "", 200, 0, {owner});
    if (!rows.length) return count;
    for (const record of rows) { app.delete(record); count++; }
  }
}
function tombstoneLibrary(app, owner) {
  let count = 0;
  for (;;) {
    const rows = app.findRecordsByFilter("gsd_library", "owner={:owner} && deleted=false", "", 200, 0, {owner});
    if (!rows.length) return count;
    for (const record of rows) {
      const prior = Date.parse(record.getString("client_updated_at"));
      const stamp = Math.max(Date.now(), Number.isFinite(prior) ? prior + 1 : 0);
      record.set("client_updated_at", new Date(stamp).toISOString());
      record.set("payload", "");
      record.set("deleted", true);
      app.save(record);
      count++;
    }
  }
}
function reset(app, owner, expected, requestId) {
  requireAccount(app, owner);
  const previous = first(app, "gsd_dataset_resets", "owner={:owner} && request_id={:requestId}", {owner, requestId});
  if (previous) {
    if (previous.getString("expected_generation") !== expected) throw apiError(409, "request_id_conflict");
    return JSON.parse(previous.getString("receipt"));
  }
  let record = state(app, owner);
  if ((record ? record.getString("generation") : "0") !== expected) throw apiError(409, "dataset_generation_mismatch");
  const next = $security.randomString(32);
  if (!record) {
    record = new Record(app.findCollectionByNameOrId("gsd_dataset_state"));
    record.set("owner", owner);
  }
  record.set("generation", next);
  app.save(record);
  const receipt = {generation: next, request_id: requestId,
    deleted_tasks: deleteTasks(app, owner), tombstoned_library: tombstoneLibrary(app, owner)};
  const saved = new Record(app.findCollectionByNameOrId("gsd_dataset_resets"));
  saved.set("owner", owner);
  saved.set("request_id", requestId);
  saved.set("expected_generation", expected);
  saved.set("receipt", JSON.stringify(receipt));
  app.save(saved);
  return receipt;
}
module.exports = {apiError, requireAccount, generation, validToken, reset};
