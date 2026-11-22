import { describe, expect, it } from "vite-plus/test";

import { MOBILE_APP_PUBLISHED } from "~/branding";
import { searchSettings, settingsForThisPlatform, SETTINGS_SEARCH_ITEMS } from "./settingsSearch";

// The store links stay hidden until this build's own mobile app is published.
describe("mobile app links in this build", () => {
  it("is not published yet", () => {
    expect(MOBILE_APP_PUBLISHED).toBe(false);
  });

  it("leaves the store row out of settings search and the command palette", () => {
    for (const query of ["App Store", "Google Play", "mobile app", "iPhone"]) {
      expect(searchSettings(query).map((item) => item.id)).not.toContain("mobile-app");
    }
    const ids = settingsForThisPlatform(SETTINGS_SEARCH_ITEMS).map((item) => item.id);
    expect(ids).not.toContain("mobile-app");
    expect(ids).toContain("welcome-page");
  });
});
