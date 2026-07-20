export async function createOpenSandboxSdk(connectionConfig) {
  const { Sandbox, SandboxManager } = await import('@alibaba-group/opensandbox');
  return {
    async find(metadata) {
      const manager = SandboxManager.create({ connectionConfig });
      try {
        const response = await manager.listSandboxInfos({ metadata, pageSize: 2 });
        if (response.items.length > 1) throw new Error('multiple OpenSandbox instances match one FKST logical run');
        if (response.items.length === 0) return null;
        return Sandbox.connect({ sandboxId: response.items[0].id, connectionConfig });
      } finally {
        await manager.close();
      }
    },
    create(options) {
      return Sandbox.create({ ...options, connectionConfig });
    },
    connect(sandboxId) {
      return Sandbox.connect({ sandboxId, connectionConfig });
    },
  };
}
