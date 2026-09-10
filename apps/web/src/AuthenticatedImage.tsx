import { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "./api";

export function AuthenticatedImage({ path, alt }: { path: string; alt: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState(160);
  const [visible, setVisible] = useState(typeof IntersectionObserver === "undefined");
  useEffect(() => {
    if (typeof IntersectionObserver === "undefined" || !ref.current) return;
    const observer = new IntersectionObserver(([entry]) => { if (!entry.isIntersecting) setHeight(Math.max(160, entry.boundingClientRect.height)); setVisible(entry.isIntersecting); }, { rootMargin: "300px" });
    observer.observe(ref.current);
    return () => observer.disconnect();
  }, []);
  return <div ref={ref} style={{ minHeight: height }}>{visible ? <VisibleImage path={path} alt={alt}/> : <div className="screen-image-state">画面画像</div>}</div>;
}

function VisibleImage({ path, alt }: { path: string; alt: string }) {
  // Offscreen images unmount: release both decoded image and cached Blob.
  const image = useQuery({ queryKey: ["screen-image", path], queryFn: ({ signal }) => api.screenImage(path, signal), staleTime: Infinity, gcTime: 0 });
  const [objectUrl, setObjectUrl] = useState<string>();
  const [failedUrl, setFailedUrl] = useState<string>();
  useEffect(() => {
    if (!image.data) { setObjectUrl(undefined); return; }
    const url = URL.createObjectURL(image.data);
    setObjectUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [image.data]);
  if (image.isError || (objectUrl && failedUrl === objectUrl)) return <div className="screen-image-state error">画像を表示できません</div>;
  if (!objectUrl) return <div className="screen-image-state">画像を読み込み中…</div>;
  return <img src={objectUrl} alt={alt} onError={() => setFailedUrl(objectUrl)}/>;
}
