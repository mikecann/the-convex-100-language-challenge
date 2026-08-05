const oracleHTTPTests = [
  "oracle/adapter/hello",
  "oracle/http/query",
  "oracle/http/nested-json-and-logs",
  "oracle/http/mutation",
  "oracle/http/idempotent-mutation",
  "oracle/http/document-id-string",
  "oracle/http/action",
  "oracle/http/structured-error",
  "oracle/http/utf8-round-trip",
  "oracle/adapter/clean-close",
];

const clientHTTPTests = [
  "client/adapter/hello",
  "client/http/query",
  "client/http/nested-json-and-logs",
  "client/http/mutation",
  "client/http/idempotent-mutation",
  "client/http/document-id-string",
  "client/http/action",
  "client/http/structured-error",
  "client/http/utf8-round-trip",
  "client/http/bearer-token-lifecycle",
  "client/adapter/clean-close",
];

const oracleLiveTests = [
  "oracle/live/initial-result",
  "oracle/live/external-update",
  "oracle/live/unsubscribe",
  "oracle/live/reconnect-five-times",
  "oracle/live/query-error-recovery",
];

const clientLiveTests = [
  "client/live/initial-result",
  "client/live/external-update",
  "client/live/unsubscribe",
  "client/live/reconnect-five-times",
  "client/live/query-error-recovery",
];

export const requiredHTTPTests = [...oracleHTTPTests, ...clientHTTPTests];
export const requiredLiveTests = [...oracleLiveTests, ...clientLiveTests];

export function hasPassingTests(resultOrTests, requiredNames) {
  const tests = Array.isArray(resultOrTests) ? resultOrTests : resultOrTests.tests;
  return requiredNames.every((name) => {
    const matches = tests.filter((test) => test.name === name);
    return matches.length === 1 && matches[0].status === "pass";
  });
}

export function earnedCapabilitiesFor(resultOrTests) {
  const httpPassed = hasPassingTests(resultOrTests, requiredHTTPTests);
  const livePassed = httpPassed && hasPassingTests(resultOrTests, requiredLiveTests);
  return [
    ...(httpPassed ? ["http"] : []),
    ...(livePassed ? ["live"] : []),
  ];
}
