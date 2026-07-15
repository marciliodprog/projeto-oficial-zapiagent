import { useState } from 'react';
import { Card } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Loader2, Plus, Pencil, Trash2, Instagram, AlertTriangle, KeyRound, Stethoscope, ShieldAlert } from 'lucide-react';
import {
  useInstagramConnections, useTestInstagramConnection, useDeleteInstagramConnection,
  useInstagramInvalidSignatureCounts,
  type InstagramConnection,
} from '@/hooks/useInstagramConnections';
import { InstagramWizard } from './InstagramWizard';
import { UpdateAppSecretDialog } from './UpdateAppSecretDialog';
import { InstagramDiagnosticsDialog } from './InstagramDiagnosticsDialog';
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent, AlertDialogDescription,
  AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip';

function StatusBadge({ c }: { c: InstagramConnection }) {
  if (c.status === 'active') return <Badge className="bg-pink-500/15 text-pink-700 border-pink-500/30">Ativa</Badge>;
  if (c.status === 'error') return <Badge variant="destructive">Erro</Badge>;
  if (c.status === 'revoked') return <Badge variant="outline">Revogada</Badge>;
  if (c.status === 'draft') return <Badge variant="secondary">Rascunho</Badge>;
  return <Badge variant="secondary">Pendente</Badge>;
}

interface Props {
  hideHeader?: boolean;
  openWizard?: boolean;
  onCloseWizard?: () => void;
}

export function InstagramConnectionsPanel({ hideHeader, openWizard, onCloseWizard }: Props = {}) {
  const { data: conns = [], isLoading } = useInstagramConnections();
  const { data: invalidCounts = {} } = useInstagramInvalidSignatureCounts();
  const test = useTestInstagramConnection();
  const del = useDeleteInstagramConnection();
  const [internalOpen, setInternalOpen] = useState(false);
  const wizardOpen = internalOpen || !!openWizard;
  const close = () => { setInternalOpen(false); setEditing(null); onCloseWizard?.(); };
  const [editing, setEditing] = useState<InstagramConnection | null>(null);
  const [toDelete, setToDelete] = useState<InstagramConnection | null>(null);
  const [secretFor, setSecretFor] = useState<InstagramConnection | null>(null);
  const [diagFor, setDiagFor] = useState<InstagramConnection | null>(null);

  if (isLoading) return <div className="flex justify-center py-8"><Loader2 className="h-6 w-6 animate-spin" /></div>;

  return (
    <TooltipProvider delayDuration={200}>
      <div className="space-y-4">
        {!hideHeader && (
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Instagram className="h-5 w-5 text-pink-500" />
              <div>
                <h3 className="font-medium">Instagram Direct (Meta)</h3>
                <p className="text-xs text-muted-foreground">Receba e responda DMs do Instagram dentro da Inbox.</p>
              </div>
            </div>
            <Button onClick={() => { setEditing(null); setInternalOpen(true); }}>
              <Plus className="h-4 w-4 mr-2" />Nova conexão
            </Button>
          </div>
        )}

        {conns.length === 0 ? null : (
          <div className="space-y-3">
            {conns.map((c) => {
              const invalidCount = invalidCounts[c.id] ?? 0;
              return (
                <Card key={c.id} className="p-4">
                  <div className="flex items-start justify-between gap-4">
                    <div className="space-y-1 min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <Instagram className="h-4 w-4 text-pink-500" />
                        <span className="font-medium">{c.display_name}</span>
                        <StatusBadge c={c} />
                        {invalidCount > 0 && (
                          <Tooltip>
                            <TooltipTrigger asChild>
                              <Badge variant="destructive" className="gap-1 cursor-help">
                                <ShieldAlert className="h-3 w-3" />
                                Assinatura inválida ({invalidCount})
                              </Badge>
                            </TooltipTrigger>
                            <TooltipContent side="bottom" className="max-w-xs">
                              A Meta enviou {invalidCount} evento(s) nos últimos 10 min, mas o App Secret salvo não bate.
                              Clique em <strong>Atualizar App Secret</strong> para corrigir.
                            </TooltipContent>
                          </Tooltip>
                        )}
                      </div>
                      <div className="text-xs text-muted-foreground">
                        {c.ig_username ? `@${c.ig_username}` : c.ig_business_account_id}
                        {c.fb_page_name && <> · Página: {c.fb_page_name}</>}
                      </div>
                      {c.status === 'error' && c.last_error && (
                        <div className="flex items-start gap-1.5 text-xs text-destructive mt-1">
                          <AlertTriangle className="h-3.5 w-3.5 mt-0.5 shrink-0" />
                          <span className="break-all">{c.last_error}</span>
                        </div>
                      )}
                    </div>
                    <div className="flex gap-1 shrink-0">
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <Button size="sm" variant="outline" onClick={() => setDiagFor(c)}>
                            <Stethoscope className="h-3.5 w-3.5" />
                          </Button>
                        </TooltipTrigger>
                        <TooltipContent>Diagnóstico do webhook</TooltipContent>
                      </Tooltip>
                      <Tooltip>
                        <TooltipTrigger asChild>
                          <Button
                            size="sm"
                            variant={invalidCount > 0 ? 'destructive' : 'outline'}
                            onClick={() => setSecretFor(c)}
                          >
                            <KeyRound className="h-3.5 w-3.5" />
                          </Button>
                        </TooltipTrigger>
                        <TooltipContent>Atualizar App Secret</TooltipContent>
                      </Tooltip>
                      <Button size="sm" variant="outline" onClick={() => test.mutate(c.id)} disabled={test.isPending}>
                        {test.isPending && test.variables === c.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : 'Testar'}
                      </Button>
                      <Button size="sm" variant="ghost" onClick={() => { setEditing(c); setInternalOpen(true); }}>
                        <Pencil className="h-3.5 w-3.5" />
                      </Button>
                      <Button size="sm" variant="ghost" onClick={() => setToDelete(c)}>
                        <Trash2 className="h-3.5 w-3.5 text-destructive" />
                      </Button>
                    </div>
                  </div>
                </Card>
              );
            })}
          </div>
        )}

        <InstagramWizard open={wizardOpen} onClose={close} editing={editing} />
        <UpdateAppSecretDialog connection={secretFor} open={!!secretFor} onOpenChange={(v) => !v && setSecretFor(null)} />
        <InstagramDiagnosticsDialog connection={diagFor} open={!!diagFor} onOpenChange={(v) => !v && setDiagFor(null)} />

        <AlertDialog open={!!toDelete} onOpenChange={(v) => !v && setToDelete(null)}>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>Remover conexão Instagram?</AlertDialogTitle>
              <AlertDialogDescription>
                Remove "{toDelete?.display_name}". Conversas e mensagens já recebidas continuam preservadas.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction
                onClick={() => { if (toDelete) del.mutate(toDelete.id); setToDelete(null); }}
                className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
              >Remover</AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </div>
    </TooltipProvider>
  );
}

