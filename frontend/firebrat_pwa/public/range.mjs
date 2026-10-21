export function rangeBounds(header, length) {
  const match=/^bytes=(\d*)-(\d*)$/.exec(header || '');
  if (!match || (!match[1]&&!match[2]) || length<=0) return null;
  const start=match[1]?Number(match[1]):Math.max(0,length-Number(match[2]));
  const end=match[1]?(match[2]?Math.min(Number(match[2]),length-1):length-1):length-1;
  return Number.isSafeInteger(start)&&Number.isSafeInteger(end)&&start>=0&&start<length&&end>=start?[start,end]:null;
}
