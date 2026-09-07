import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { api } from "./api";

export function AuthenticatedImage({ path, alt }: { path: string; alt: string }) {
  const image = useQuery({ queryKey: ["screen-image", path], queryFn: () => api.screenImage(path), staleTime: Infinity });
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
