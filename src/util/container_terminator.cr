module Netwrangler::Util
  # The process that owns the container's lifetime. A hook runs as a child of
  # it, so a hook exiting on its own never stops the container — only signalling
  # this process does.
  INIT_PROCESS_ID = 1_i64

  # Stops the container by asking its supervising process to shut down, so the
  # kubelet restarts the pod and the restart becomes visible in its status.
  record ContainerTerminator,
    process_id : Int64 = INIT_PROCESS_ID do
    def terminate : Nil
      Process.signal(Signal::TERM, process_id)
    end
  end
end
