export interface QgModuleHtmlNode {
  tag: string;
  attrs: Record<string, string>;
  text: string;
  children: QgModuleHtmlNode[];
}
export function parseModuleHtml(text: string): QgModuleHtmlNode;
