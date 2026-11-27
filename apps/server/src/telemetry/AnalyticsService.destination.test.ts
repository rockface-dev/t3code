import * as NodeCrypto from "@effect/platform-node/NodeCrypto";
import * as NodeHttpServer from "@effect/platform-node/NodeHttpServer";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import * as ConfigProvider from "effect/ConfigProvider";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as HttpServer from "effect/http/HttpServer";
import * as HttpServerRequest from "effect/http/HttpServerRequest";
import * as HttpServerResponse from "effect/http/HttpServerResponse";
import * as HostProcess from "@t3tools/shared/HostProcess";

import * as ServerConfig from "../config.ts";
import * as ManagedPolicy from "../policy/ManagedPolicy.ts";
import * as AnalyticsService from "./AnalyticsService.ts";

const recordOneEvent = (destination: { readonly key: string; readonly host: string }) =>
  Effect.gen(function* () {
    const sentPaths: Array<string> = [];
    const layerBatchServer = HttpServer.serve(
      Effect.gen(function* () {
        const request = yield* HttpServerRequest.HttpServerRequest;
        sentPaths.push(request.url);
        return HttpServerResponse.jsonUnsafe({});
      }),
    );
    const layerRuntime = AnalyticsService.layer.pipe(
      Layer.provideMerge(
        ServerConfig.ServerConfig.layerTest(process.cwd(), { prefix: "t3-telemetry-nodest-" }),
      ),
      Layer.provide(
        ConfigProvider.layer(
          ConfigProvider.fromUnknown({
            T3CODE_TELEMETRY_ENABLED: true,
            T3CODE_TELEMETRY_KEY: destination.key,
            T3CODE_TELEMETRY_HOST: destination.host,
          }),
        ),
      ),
      Layer.provide(
        Layer.mergeAll(
          Layer.succeed(HostProcess.Platform, "linux"),
          Layer.succeed(HostProcess.Architecture, "arm64"),
          ManagedPolicy.layerTest(),
        ),
      ),
      Layer.provideMerge(NodeHttpServer.layerTest),
    );

    const recorded = yield* Effect.gen(function* () {
      yield* Layer.launch(layerBatchServer).pipe(Effect.forkScoped);
      const analytics = yield* AnalyticsService.AnalyticsService;
      const accepted = yield* analytics.record("test.destination", { index: 1 });
      yield* analytics.flush;
      return accepted;
    }).pipe(Effect.provide(layerRuntime));

    return { recorded, sent: sentPaths.length };
  });

it.layer(Layer.mergeAll(NodeServices.layer, NodeCrypto.layer))("Analytics destination", (it) => {
  it.effect("records and sends nothing while the key or the host is empty", () =>
    Effect.gen(function* () {
      const both = yield* recordOneEvent({ key: "phc_test_key", host: "http://localhost" });
      const noHost = yield* recordOneEvent({ key: "phc_test_key", host: "" });
      const noKey = yield* recordOneEvent({ key: "", host: "http://localhost" });

      assert.deepEqual(both, { recorded: true, sent: 1 });
      assert.deepEqual(noHost, { recorded: false, sent: 0 });
      assert.deepEqual(noKey, { recorded: false, sent: 0 });
    }),
  );
});
