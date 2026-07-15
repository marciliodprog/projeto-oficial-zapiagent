import { useMemo } from 'react';
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Badge } from '@/components/ui/badge';
import { ScrollArea } from '@/components/ui/scroll-area';
import { CheckCircle2, XCircle, Stethoscope, Clock } from 'lucide-react';
import { useInstagramWebhookLogs, type InstagramConnection } from '@/hooks/useInstagramConnections';
import { formatDistanceToNow } from 'date-fns';
import { ptBR } from 'date-fns/locale';

interface Props {
  connection: InstagramConnection | null;
  open: boolean;
  onOpenChange: (v: boolean) => void;
}

export function InstagramDiagnosticsDialog({ connection, open, onOpenChange }: Props) {
  const { data: logs = [], isLoading } = useInstagramWebhookLogs(connection?.id ?? null, 40);

  const counts = useMemo(() => {
    const since = Date.now() - 10 * 60 * 1000;
    const out: Record<string, number> = {};
    for (const l of logs) {
      if (new Date(l.created_at).getTime() < since) continue;
      out[l.event_type] = (out[l.event_type] ?? 0) + 1;
    }
    return out;
  }, [logs]);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-3xl max-h-[85vh]">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Stethoscope className="h-5 w-5 text-primary" /> Diagnóstico do Webhook — {connection?.display_name}
          </DialogTitle>
          <DialogDescription>
            Últimos eventos recebidos pela Meta para esta conexão. Atualiza automaticamente a cada 8s.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-wrap gap-2 pb-2">
          <span className="text-xs text-muted-foreground flex items-center gap-1">
            <Clock className="h-3 w-3" /> Últimos 10 min:
          </span>
          {Object.keys(counts).length === 0 ? (
            <span className="text-xs text-muted-foreground">nenhum evento</span>
          ) : (
            Object.entries(counts).map(([type, n]) => (
              <Badge
                key={type}
                variant={type === 'invalid_signature' ? 'destructive' : 'secondary'}
                className="font-mono text-xs"
              >
                {type}: {n}
              </Badge>
            ))
          )}
        </div>

        <ScrollArea className="h-[55vh] pr-3 -mr-3">
          {isLoading ? (
            <p className="text-sm text-muted-foreground py-8 text-center">carregando…</p>
          ) : logs.length === 0 ? (
            <div className="text-sm text-muted-foreground py-12 text-center space-y-2">
              <p>Nenhum evento recebido ainda.</p>
              <p className="text-xs">
                Verifique se você configurou <em>URL de callback</em> e <em>Verify Token</em> no App da Meta
                (Casos de uso → API do Instagram → Webhooks) e assinou os campos.
              </p>
            </div>
          ) : (
            <ul className="space-y-2">
              {logs.map((l) => {
                const bad = l.event_type === 'invalid_signature' || l.signature_valid === false;
                const summary = l.payload_summary as any;
                return (
                  <li key={l.id} className="rounded-md border p-2.5 text-xs space-y-1">
                    <div className="flex items-center justify-between gap-2">
                      <div className="flex items-center gap-2 min-w-0">
                        {bad ? <XCircle className="h-3.5 w-3.5 text-destructive shrink-0" /> : <CheckCircle2 className="h-3.5 w-3.5 text-emerald-500 shrink-0" />}
                        <span className="font-mono font-medium">{l.event_type}</span>
                        {summary?.change_fields?.length ? (
                          <span className="text-muted-foreground truncate">· {summary.change_fields.join(', ')}</span>
                        ) : null}
                      </div>
                      <span className="text-muted-foreground shrink-0">
                        {formatDistanceToNow(new Date(l.created_at), { addSuffix: true, locale: ptBR })}
                      </span>
                    </div>
                    {l.error && <p className="text-destructive">{l.error}</p>}
                    {summary && (
                      <div className="text-muted-foreground flex flex-wrap gap-x-3 gap-y-0.5">
                        {summary.entry_id && <span>entry: <span className="font-mono">{summary.entry_id}</span></span>}
                        {summary.sig_prefix && <span>sig: <span className="font-mono">{summary.sig_prefix}…</span></span>}
                        {typeof summary.has_messaging === 'boolean' && <span>DM: {summary.has_messaging ? 'sim' : 'não'}</span>}
                        {typeof summary.has_changes === 'boolean' && <span>changes: {summary.has_changes ? 'sim' : 'não'}</span>}
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </ScrollArea>
      </DialogContent>
    </Dialog>
  );
}
