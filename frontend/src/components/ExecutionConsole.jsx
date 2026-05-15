import React, { useRef, useEffect, useState } from 'react';
import { Terminal, Trash2, Download, CheckCircle, Loader, AlertCircle, Copy } from 'lucide-react';

function classifyLine(text) {
  const t = text.toLowerCase();
  if (t.includes('error') || t.includes('exception') || t.includes('fail')) return 'err';
  if (t.includes('warn')) return 'warn';
  if (t.includes('verbose') || t.includes('debug')) return 'info';
  if (t.includes('success') || t.includes('complete') || t.includes('done')) return 'ok';
  return '';
}

export default function ExecutionConsole({ logLines, activeJob, setLogLines }) {
  const endRef = useRef(null);
  const [copied, setCopied] = useState(false);

  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }); }, [logLines]);

  const copy = () => {
    navigator.clipboard.writeText(logLines.map((l) => l.text).join('\n'));
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const dlLog = () => {
    const blob = new Blob([logLines.map((l) => l.text).join('\n')], { type: 'text/plain' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `asbuiltreport-${Date.now()}.log`;
    a.click();
  };

  const isRunning = !!activeJob;
  const hasErrors = logLines.some((l) => l.type === 'err');

  return (
    <div className="h-full flex flex-col bg-abr-bg">
      {/* Console Header */}
      <div className="px-6 py-4 border-b border-abr-border flex items-center gap-3">
        <Terminal size={16} className="text-abr-accent" />
        <div>
          <h1 className="text-sm font-semibold text-abr-text">Execution Console</h1>
          <p className="text-xs text-abr-sub font-mono">{activeJob || 'No active job'}</p>
        </div>

        <div className="flex items-center gap-2 ml-auto">
          {/* Status badge */}
          {isRunning && (
            <span className="flex items-center gap-1.5 text-xs text-abr-warn bg-abr-warn/10 border border-abr-warn/20 px-2.5 py-1 rounded-full">
              <Loader size={10} className="animate-spin" /> Running
            </span>
          )}
          {!isRunning && logLines.length > 0 && !hasErrors && (
            <span className="flex items-center gap-1.5 text-xs text-abr-success bg-abr-success/10 border border-abr-success/20 px-2.5 py-1 rounded-full">
              <CheckCircle size={10} /> Completed
            </span>
          )}
          {!isRunning && hasErrors && (
            <span className="flex items-center gap-1.5 text-xs text-abr-danger bg-abr-danger/10 border border-abr-danger/20 px-2.5 py-1 rounded-full">
              <AlertCircle size={10} /> Errors Detected
            </span>
          )}

          <button onClick={copy} title="Copy log" className="p-1.5 text-abr-sub hover:text-abr-text rounded border border-abr-border hover:border-abr-muted transition-all">
            <Copy size={13} />
          </button>
          <button onClick={dlLog} title="Download log" className="p-1.5 text-abr-sub hover:text-abr-text rounded border border-abr-border hover:border-abr-muted transition-all">
            <Download size={13} />
          </button>
          <button onClick={() => setLogLines([])} title="Clear" className="p-1.5 text-abr-sub hover:text-abr-danger rounded border border-abr-border hover:border-abr-danger/40 transition-all">
            <Trash2 size={13} />
          </button>
        </div>
      </div>

      {/* Terminal Body */}
      <div className="flex-1 overflow-y-auto p-4 font-mono text-xs" style={{ background: '#070709' }}>
        {/* Scanline effect */}
        <div className="pointer-events-none fixed inset-0 opacity-[0.015]"
          style={{ backgroundImage: 'repeating-linear-gradient(0deg, #000 0px, #000 1px, transparent 1px, transparent 2px)', backgroundSize: '100% 2px' }} />

        {logLines.length === 0 && (
          <div className="flex flex-col items-center justify-center h-full gap-3 text-abr-sub">
            <Terminal size={32} className="opacity-20" />
            <p className="text-sm">Waiting for output…</p>
            <p className="text-xs opacity-60">Configure a module and click "Run Report" to start</p>
          </div>
        )}

        {logLines.map((line, i) => {
          const cls = line.type === 'err' ? 'err' : line.type === 'warn' ? 'warn' : classifyLine(line.text);
          return (
            <div key={i} className={`term-line ${cls} flex gap-3 py-0.5 group hover:bg-white/[0.02] rounded px-1 -mx-1`}>
              <span className="text-abr-sub/40 select-none tabular-nums w-8 text-right shrink-0">{i + 1}</span>
              <span className="break-all">{line.text}</span>
            </div>
          );
        })}

        {/* Blinking cursor */}
        {isRunning && (
          <div className="flex gap-3 py-0.5 px-1">
            <span className="text-abr-sub/40 select-none tabular-nums w-8 text-right shrink-0">{logLines.length + 1}</span>
            <span className="text-abr-accent animate-pulse-dot">█</span>
          </div>
        )}

        <div ref={endRef} />
      </div>

      {/* Bottom status bar */}
      <div className="px-4 py-2 border-t border-abr-border bg-abr-surface flex items-center gap-4 text-xs text-abr-sub font-mono">
        <span>{logLines.length} lines</span>
        <span>·</span>
        <span className="text-abr-danger">{logLines.filter((l) => l.type === 'err').length} errors</span>
        <span>·</span>
        <span className="text-abr-warn">{logLines.filter((l) => classifyLine(l.text) === 'warn').length} warnings</span>
        {copied && <span className="ml-auto text-abr-success">Copied to clipboard ✓</span>}
      </div>
    </div>
  );
}
