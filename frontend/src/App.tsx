/** pi-zig workbench: a restrained, work-focused console for the Zig RPC backend. */

import { useState } from 'preact/hooks';
import { BashConsole } from './components/BashConsole';
import { Composer } from './components/Composer';
import { EventLog } from './components/EventLog';
import { SessionInfo } from './components/SessionInfo';
import { Settings } from './components/Settings';
import { SlashCommands } from './components/SlashCommands';
import { StatusBar, Toasts } from './components/StatusBar';
import { Transcript } from './components/Transcript';
import { useWorkbenchState } from './hooks';

type MobileTab = 'chat' | 'controls';

export function App() {
  const state = useWorkbenchState();
  const [mobileTab, setMobileTab] = useState<MobileTab>('chat');

  return (
    <div class="workbench" data-mobile-tab={mobileTab}>
      <StatusBar />

      <div class="mobile-tabs">
        <button class="mobile-tab" data-active={mobileTab === 'chat'} onClick={() => setMobileTab('chat')}>
          Conversation
        </button>
        <button class="mobile-tab" data-active={mobileTab === 'controls'} onClick={() => setMobileTab('controls')}>
          Controls
        </button>
      </div>

      <main class="layout">
        <section class="conversation" aria-label="Conversation">
          <Transcript
            messages={state.messages}
            loading={state.loadingMessages}
            streaming={(state.state?.isStreaming ?? false) || state.busy}
          />
          <Composer />
        </section>

        <aside class="sidebar" aria-label="Controls">
          <SessionInfo />
          <Settings />
          <SlashCommands />
          <BashConsole />
          <EventLog />
        </aside>
      </main>

      <Toasts />
    </div>
  );
}
