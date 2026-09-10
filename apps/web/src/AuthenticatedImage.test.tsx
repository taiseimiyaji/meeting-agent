// @vitest-environment jsdom
import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, expect, it, vi } from "vitest";
import { AuthenticatedImage } from "./AuthenticatedImage";
const fetchImage = vi.hoisted(() => vi.fn());
vi.mock("./api", () => ({ api: { screenImage: fetchImage } }));
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });
it("loads only visible images and releases the Blob and object URL on exit", async () => {
  let notify: IntersectionObserverCallback;
  vi.stubGlobal("IntersectionObserver", class {
    constructor(callback: IntersectionObserverCallback) { notify = callback; }
    observe() {} disconnect() {}
  });
  const create = vi.fn(() => "blob:visible");
  const revoke = vi.fn();
  vi.stubGlobal("URL", Object.assign(URL, { createObjectURL: create, revokeObjectURL: revoke }));
  fetchImage.mockResolvedValue(new Blob(["image"]));
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(<QueryClientProvider client={client}><AuthenticatedImage path="/one" alt="会議画面"/></QueryClientProvider>);
  expect(fetchImage).not.toHaveBeenCalled();
  const entry = (visible: boolean) => [{ isIntersecting: visible, boundingClientRect: { height: 220 } }] as IntersectionObserverEntry[];
  act(() => notify(entry(true), {} as IntersectionObserver));
  expect(await screen.findByRole("img", { name: "会議画面" })).toBeTruthy();
  expect(fetchImage).toHaveBeenCalledTimes(1);
  act(() => notify(entry(false), {} as IntersectionObserver));
  expect(screen.queryByRole("img")).toBeNull();
  expect(revoke).toHaveBeenCalledWith("blob:visible");
  await waitFor(() => expect(client.getQueryData(["screen-image", "/one"])).toBeUndefined());
});
