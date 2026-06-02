-- artifact_transfer_t pipeline

sleep_time = 2

p = pipeline {
  node1 = shn(command = "sleep 2 && echo 'Node 1'", capture = "stdout")
  node2 = shn(command = "sleep " + to_string(sleep_time) + " && echo 'Node 2'", capture = "stdout")
  node3 = shn(command = "sleep 2 && echo 'Node 3'", capture = "stdout")
}

populate_pipeline(p, build = true, verbose = 1)
