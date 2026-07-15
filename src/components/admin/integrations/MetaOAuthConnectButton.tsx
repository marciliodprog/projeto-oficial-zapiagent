import { useState } from 'react';
import { supabase } from '@/integrations/supabase/client';
import { Button } from '@/components/ui/button';
import { Facebook, Loader2 } from 'lucide-react';
import { toast } from 'sonner';
import { MetaOAuthPickerDialog } from './MetaOAuthPickerDialog';

interface Props {
  organizationId: string;
  purpose?: 'instagram' | 'ads' | 'both';
  label?: string;
  className?: string;
  onConnected?: () => void;
}

export function MetaOAuthConnectButton({ organizationId, purpose = 'both', label, className, onConnected }: Props) {
  const [busy, setBusy] = useState(false);
  const [sessionId, setSessionId] = useState<string | null>(null);

  const start = async () => {
    setBusy(true);
    try {
      const { data: { session } } = await supabase.auth.getSession();
      const sbToken = session?.access_token;
      if (!sbToken) { toast.error('Faça login novamente.'); setBusy(false); return; }
      const url = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/meta-oauth-start?org_id=${organizationId}&purpose=${purpose}&sb_token=${encodeURIComponent(sbToken)}`;
      const popup = window.open(url, 'meta-oauth', 'width=560,height=720');
      if (!popup) { toast.error('Bloqueador de popups impediu a janela.'); setBusy(false); return; }

      const listener = (ev: MessageEvent) => {
        const d = ev.data;
        if (!d || d.source !== 'meta-oauth') return;
        window.removeEventListener('message', listener);
        setBusy(false);
        if (d.status === 'ready' && d.session_id) {
          setSessionId(d.session_id);
        } else {
          toast.error(`Falha no OAuth: ${d.error || 'desconhecido'}`);
        }
      };
      window.addEventListener('message', listener);

      // Fallback: se o popup fechar sem responder
      const poll = setInterval(() => {
        if (popup.closed) {
          clearInterval(poll);
          setTimeout(() => { setBusy(false); }, 800);
        }
      }, 500);
    } catch (e: any) {
      toast.error(e?.message || 'Erro ao iniciar OAuth');
      setBusy(false);
    }
  };

  return (
    <>
      <Button onClick={start} disabled={busy} className={className}>
        {busy ? <Loader2 className="h-4 w-4 mr-2 animate-spin" /> : <Facebook className="h-4 w-4 mr-2" />}
        {label || 'Conectar com Facebook'}
      </Button>
      {sessionId && (
        <MetaOAuthPickerDialog
          sessionId={sessionId}
          purpose={purpose}
          onClose={() => setSessionId(null)}
          onDone={() => { setSessionId(null); onConnected?.(); }}
        />
      )}
    </>
  );
}
