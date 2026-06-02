-- artifact_transfer_t pipeline definition

p = pipeline {
  node1 = shn(command = <{ sleep 20 && echo "Node 1" }>)
  node2 = shn(command = <{ sleep 20 && echo "Node 2" }>)
  node3 = shn(command = <{ sleep 20 && echo "Node 3" }>)
}
