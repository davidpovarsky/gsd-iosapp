// Keep owner/generation validation and the standard create form in one write transaction.
onRecordCreateRequest((e) => {
  const helper = require(__hooks + "/gsd_dataset_helpers.js");
  const headers = e.requestInfo().headers;
  const key = "x_gsd_dataset_generation";
  const expected = Object.prototype.hasOwnProperty.call(headers, key) ? headers[key] : null;
  if (expected !== null && !helper.validToken(expected))
    throw helper.apiError(400, "invalid_dataset_generation");
  const originalApp = e.app;
  originalApp.runInTransaction((tx) => {
    const owner = e.record.getString("owner");
    helper.requireAccount(tx, owner);
    if (expected !== null && helper.generation(tx, owner) !== expected)
      throw helper.apiError(409, "dataset_generation_mismatch");
    e.app = tx;
    try { e.next(); } finally { e.app = originalApp; }
  });
}, "tasks");

routerAdd("GET", "/api/gsd/dataset", (e) => {
  const helper = require(__hooks + "/gsd_dataset_helpers.js");
  let generation;
  e.app.runInTransaction((tx) => {
    helper.requireAccount(tx, e.auth.id);
    generation = helper.generation(tx, e.auth.id);
  });
  return e.json(200, {generation});
}, $apis.requireAuth("users"));

routerAdd("POST", "/api/gsd/dataset/reset", (e) => {
  const helper = require(__hooks + "/gsd_dataset_helpers.js");
  const body = e.requestInfo().body || {};
  if (Object.keys(body).length !== 2 || !helper.validToken(body.expected_generation) || !helper.validToken(body.request_id))
    throw helper.apiError(400, "invalid_dataset_reset");
  let receipt;
  e.app.runInTransaction((tx) => {
    receipt = helper.reset(tx, e.auth.id, body.expected_generation, body.request_id);
  });
  return e.json(200, receipt);
}, $apis.requireAuth("users"));
