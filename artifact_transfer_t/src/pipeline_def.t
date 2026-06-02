-- artifact_transfer_t pipeline definition

p = pipeline {
  node1 = shn(command = <{ sleep 20 && echo "Node 1" }>)
  node2 = shn(command = <{ sleep 20 && echo "Node 2" }>, deps = [node1])
  node3 = shn(command = <{ echo "Node 3" }>, deps = [node2])
}
